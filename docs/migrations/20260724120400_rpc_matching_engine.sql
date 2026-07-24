-- =============================================================================
-- Phase 4 & Phase 5 RPCs — Matching Engine Core & Candidate Confirmation
-- 派生自 docs/SPEC.md §7、§12.1 及 docs/API.md §4、§9
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: commit_match
-- 原子性提交配對結果（將 2 個 Request 併入 Activity 或 PENDING_CONFIRMATION）
-- -----------------------------------------------------------------------------

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
  v_activity   activity;
  v_dur        int;
  v_start_time timestamptz;
begin
  -- 鎖定雙方 Request 進行原子處理
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using errcode = 'NOT_FOUND', message = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_count_a from request_member where request_id = p_request_a_id and status = 'JOINED';
  select count(*) into v_count_b from request_member where request_id = p_request_b_id and status = 'JOINED';
  v_total := v_count_a + v_count_b;

  -- 取得活動類型的預設時長（fallback 60m）
  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_req_a.activity_type_id;

  v_start_time := greatest(v_req_a.earliest_start, v_req_b.earliest_start);

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    insert into activity (
      activity_type_id, campus_location_id, start_time, estimated_end_time,
      status, contact_visible_until
    ) values (
      v_req_a.activity_type_id, v_req_a.campus_location_id,
      v_start_time, v_start_time + (v_dur || ' minutes')::interval,
      'MATCHED', now() + interval '24 hours'
    )
    returning * into v_activity;

    -- 寫入 activity_member
    insert into activity_member (activity_id, user_id, source_request_id, status)
    select v_activity.id, rm.user_id, p_request_a_id, 'JOINED'
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into activity_member (activity_id, user_id, source_request_id, status)
    select v_activity.id, rm.user_id, p_request_b_id, 'JOINED'
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    -- 更新 Request 狀態
    update match_request set status = 'MATCHED' where id in (p_request_a_id, p_request_b_id);

    -- 發送通知
    insert into notification (user_id, event_type, payload)
    select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
      from activity_member am where am.activity_id = v_activity.id;

    return v_activity;

  -- 分支 2：實際撮合人數 <= 2 → 建立 pending_confirmation (R3b)
  else
    insert into pending_confirmation (
      request_a_id, request_b_id, confirm_window_expire_at, status
    ) values (
      p_request_a_id, p_request_b_id, now() + interval '10 minutes', 'PENDING'
    );

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    return null;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: fn_run_matching_engine
-- 貪婪撮合引擎 (Greedy Close Matching Engine)
-- -----------------------------------------------------------------------------

create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec        record;
  v_req_a      record;
  v_req_b      record;
  v_match_count int := 0;
  v_user_a     uuid;
  v_user_b     uuid;
  v_pair_a     uuid;
  v_pair_b     uuid;
begin
  -- 遍歷所有有 REQUESTING 狀態 Request 的 (activity_type, location) 組合
  for v_rec in (
    select distinct activity_type_id, campus_location_id
      from match_request
     where status = 'REQUESTING'
  ) loop
    -- 尋找可撮合的 Request 對
    for v_req_a in (
      select * from match_request
       where activity_type_id = v_rec.activity_type_id
         and campus_location_id = v_rec.campus_location_id
         and status = 'REQUESTING'
       order by created_at asc
    ) loop
      -- 尋找配對對象 v_req_b
      select * into v_req_b
        from match_request r
       where r.activity_type_id = v_rec.activity_type_id
         and r.campus_location_id = v_rec.campus_location_id
         and r.status = 'REQUESTING'
         and r.id <> v_req_a.id
         and r.earliest_start <= v_req_a.latest_start
         and r.latest_start >= v_req_a.earliest_start
         and not exists (
           -- 避雷降權檢查 (match_history_avoidance，Pair 正規化)
           select 1 from match_history_avoidance mha
            where mha.expire_at > now()
              and (
                (mha.user_a_id = least(v_req_a.owner_id, r.owner_id)
                 and mha.user_b_id = greatest(v_req_a.owner_id, r.owner_id))
              )
         )
       limit 1;

      if v_req_b.id is not null then
        -- 執行撮合提交
        perform commit_match(v_req_a.id, v_req_b.id);
        v_match_count := v_match_count + 1;
      end if;
    end loop;
  end loop;

  return v_match_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Candidate Confirmation 受控讀取與回應 RPCs (v1.4)
-- -----------------------------------------------------------------------------

-- 3a. get_pending_confirmation_status (對稱不歸因專用讀取)
create or replace function get_pending_confirmation_status(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_pc      pending_confirmation;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select * into v_pc
    from pending_confirmation
   where (request_a_id = p_request_id or request_b_id = p_request_id)
   order by created_at desc
   limit 1;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  -- 嚴格落實對稱不歸因原則 (ERD 備註 16)：只回傳整體 status 與倒數時間，不透露個人 response 明細
  return jsonb_build_object(
    'pending_confirmation_id', v_pc.id,
    'status', v_pc.status,
    'confirm_window_expire_at', v_pc.confirm_window_expire_at
  );
end;
$$;

-- 3b. respond_pending_confirmation (原子性回應與狀態變更)
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
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select * into v_pc
    from pending_confirmation
   where id = p_pending_confirmation_id
     for update;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  if v_pc.status <> 'PENDING' then
    raise exception using errcode = 'CONFIRMATION_WINDOW_CLOSED', message = 'CONFIRMATION_WINDOW_CLOSED';
  end if;

  -- 判定呼叫者是 Party A 還是 Party B
  if exists (select 1 from match_request where id = v_pc.request_a_id and owner_id = v_user_id) then
    v_is_user_a := true;
    v_other_resp := v_pc.user_b_response;
  elsif exists (select 1 from match_request where id = v_pc.request_b_id and owner_id = v_user_id) then
    v_is_user_a := false;
    v_other_resp := v_pc.user_a_response;
  else
    raise exception using errcode = 'FORBIDDEN', message = 'NOT_PARTY_TO_CONFIRMATION';
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
  elsif v_other_resp = 'CONFIRMED' then
    -- 雙方皆同意 → 觸發 PC1 建立 Activity
    update pending_confirmation set status = 'CONFIRMED' where id = v_pc.id;
    perform commit_match(v_pc.request_a_id, v_pc.request_b_id);
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. rpc: fn_cleanup_pending_confirmations
-- 背景 Worker 觸發之超時與拒絕清理程序 (PC2)
-- -----------------------------------------------------------------------------

create or replace function fn_cleanup_pending_confirmations()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pc       record;
  v_user_a   uuid;
  v_user_b   uuid;
  v_count    int := 0;
begin
  for v_pc in (
    select pc.*, ra.owner_id as owner_a, rb.owner_id as owner_b,
           ra.latest_start as latest_a, rb.latest_start as latest_b
      from pending_confirmation pc
      join match_request ra on ra.id = pc.request_a_id
      join match_request rb on rb.id = pc.request_b_id
     where (pc.confirm_window_expire_at < now() and pc.status = 'PENDING')
        or pc.status = 'DECLINED'
  ) loop
    -- 1. 更新 pending_confirmation 狀態
    if v_pc.status = 'PENDING' then
      update pending_confirmation set status = 'TIMEOUT' where id = v_pc.id;
    end if;

    -- 2. 寫入 match_history_avoidance (Pair 正規化)
    v_user_a := least(v_pc.owner_a, v_pc.owner_b);
    v_user_b := greatest(v_pc.owner_a, v_pc.owner_b);

    insert into match_history_avoidance (
      user_a_id, user_b_id, source_pending_confirmation_id, expire_at
    ) values (
      v_user_a, v_user_b, v_pc.id, now() + interval '7 days'
    );

    -- 3. 雙方 Request 無差別對稱退回 Queue (REQUESTING)
    if v_pc.latest_a > now() then
      update match_request set status = 'REQUESTING' where id = v_pc.request_a_id;
    else
      update match_request set status = 'EXPIRED' where id = v_pc.request_a_id;
    end if;

    if v_pc.latest_b > now() then
      update match_request set status = 'REQUESTING' where id = v_pc.request_b_id;
    else
      update match_request set status = 'EXPIRED' where id = v_pc.request_b_id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
