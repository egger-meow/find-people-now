-- =============================================================================
-- Bug fix — commit_match 的 <=2 人分支在 PC1 (respond_pending_confirmation 雙方
-- 皆確認) 重入時被再次觸發，導致重複插入 pending_confirmation 而不是建立 Activity
-- =============================================================================
--
-- 根因：commit_match 純粹依 v_total = count(request_member) 決定分支，這個計數
-- 在 Matching Engine 第一次呼叫、與 respond_pending_confirmation 雙方確認後的第
-- 二次呼叫之間完全沒變（仍然 <=2），於是第二次呼叫又走進「建立 pending_confirmation」
-- 分支，插入第二筆 pending_confirmation，永遠不會建立 Activity；原本那筆
-- pending_confirmation 的 status 雖然正確被標成 CONFIRMED，但 match_request.status
-- 永遠卡在 PENDING_CONFIRMATION。
--
-- 修法：拆出 fn_create_activity_from_requests，把「無條件把兩個 Request 併入一個
-- 新 Activity」這段邏輯獨立出來（原 commit_match 分支 1 的內容，原封不動搬移）。
--   - commit_match：分支 1 (v_total > 2) 改為呼叫這個新函數；分支 2 邏輯不變。只給
--     fn_run_matching_engine（第一次撮合）使用。
--   - respond_pending_confirmation 的 PC1 段落（雙方皆 CONFIRMED）：不再呼叫
--     commit_match，改直接呼叫 fn_create_activity_from_requests——這個時間點已經
--     不需要再問一次「要不要建 pending_confirmation」，語義上就是無條件建立 Activity。
-- =============================================================================

create or replace function fn_create_activity_from_requests(
  p_request_a_id uuid,
  p_request_b_id uuid
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req_a      match_request;
  v_req_b      match_request;
  v_activity   activity;
  v_dur        int;
  v_start_time timestamptz;
begin
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_req_a.activity_type_id;

  v_start_time := greatest(v_req_a.earliest_start, v_req_b.earliest_start);

  insert into activity (
    activity_type_id, school, campus, start_time, estimated_end_time,
    status, contact_visible_until
  ) values (
    v_req_a.activity_type_id, v_req_a.school, v_req_a.campus,
    v_start_time, v_start_time + (v_dur || ' minutes')::interval,
    'MATCHED', now() + interval '24 hours'
  )
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity.id, rm.user_id, p_request_a_id, 'JOINED'
    from request_member rm
   where rm.request_id = p_request_a_id and rm.status = 'JOINED';

  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity.id, rm.user_id, p_request_b_id, 'JOINED'
    from request_member rm
   where rm.request_id = p_request_b_id and rm.status = 'JOINED';

  update match_request set status = 'MATCHED' where id in (p_request_a_id, p_request_b_id);

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
    from activity_member am where am.activity_id = v_activity.id;

  return v_activity;
end;
$$;

create or replace function commit_match(
  p_request_a_id uuid,
  p_request_b_id uuid
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req_a      match_request;
  v_req_b      match_request;
  v_count_a    int;
  v_count_b    int;
  v_total      int;
begin
  -- 鎖定雙方 Request 進行原子處理
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_count_a from request_member where request_id = p_request_a_id and status = 'JOINED';
  select count(*) into v_count_b from request_member where request_id = p_request_b_id and status = 'JOINED';
  v_total := v_count_a + v_count_b;

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    return fn_create_activity_from_requests(p_request_a_id, p_request_b_id);

  -- 分支 2：實際撮合人數 <= 2 → 建立 pending_confirmation (R3b)
  else
    insert into pending_confirmation (
      request_a_id, request_b_id, confirm_window_expire_at, status
    ) values (
      p_request_a_id, p_request_b_id, now() + fn_get_config_interval('confirm_window_minutes'), 'PENDING'
    );

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    return null;
  end if;
end;
$$;

-- respond_pending_confirmation：PC1（雙方皆 CONFIRMED）不再呼叫 commit_match
-- （會被自己的人數判斷卡在 <=2 分支，見上方根因說明），改直接無條件建立 Activity。
create or replace function respond_pending_confirmation(
  p_pending_confirmation_id uuid,
  p_confirm                  boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_pc          pending_confirmation;
  v_is_user_a   boolean := false;
  v_new_resp    pending_confirmation_response;
  v_other_resp  pending_confirmation_response;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_pc
    from pending_confirmation
   where id = p_pending_confirmation_id
     for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  if v_pc.status <> 'PENDING' then
    raise exception using message = 'CONFIRMATION_WINDOW_CLOSED';
  end if;

  -- 判定呼叫者是 Party A 還是 Party B
  if exists (select 1 from match_request where id = v_pc.request_a_id and owner_id = v_user_id) then
    v_is_user_a := true;
    v_other_resp := v_pc.user_b_response;
  elsif exists (select 1 from match_request where id = v_pc.request_b_id and owner_id = v_user_id) then
    v_is_user_a := false;
    v_other_resp := v_pc.user_a_response;
  else
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_CONFIRMATION';
  end if;

  v_new_resp := case when p_confirm then 'CONFIRMED'::pending_confirmation_response else 'DECLINED'::pending_confirmation_response end;

  -- 原子性更新呼叫者自己的欄位
  if v_is_user_a then
    update pending_confirmation
       set user_a_response = v_new_resp
     where id = v_pc.id;
  else
    update pending_confirmation
       set user_b_response = v_new_resp
     where id = v_pc.id;
  end if;

  -- 原子性判定狀態轉移
  if p_confirm = false then
    -- 任一方拒絕 → 標記 DECLINED (清理作業由 Worker 或背景掃描執行)
    update pending_confirmation set status = 'DECLINED' where id = v_pc.id;

    -- 主動拒絕觸發冷卻 (v1.7，SPEC §6.3；冷卻時長來自 app_config.cooldown_minutes)；TIMEOUT 由背景 Worker 處理，不經過這裡，不觸發
    update app_user set next_request_allowed_at = now() + fn_get_config_interval('cooldown_minutes') where id = v_user_id;
  elsif v_other_resp = 'CONFIRMED' then
    -- 雙方皆同意 → 觸發 PC1，無條件建立 Activity（不經過 commit_match 的人數分支判斷）
    update pending_confirmation set status = 'CONFIRMED' where id = v_pc.id;
    perform fn_create_activity_from_requests(v_pc.request_a_id, v_pc.request_b_id);
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- 不需要額外 grant execute：Postgres 對函式的 EXECUTE 預設就是 GRANT 給 PUBLIC
-- （見 20260724120800_grants.sql 的說明），fn_create_activity_from_requests 沿用同一慣例。
