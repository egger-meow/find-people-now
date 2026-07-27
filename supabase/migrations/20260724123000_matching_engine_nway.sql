-- =============================================================================
-- v1.15 — Matching Engine 改成 N 方累積演算法（核心邏輯修正）
-- =============================================================================
--
-- 根因（使用者診斷 + 本輪核對確認）：
--   1. 舊版 fn_run_matching_engine() 純粹兩兩配對，每個 v_req_a 只用 limit 1 找一個
--      v_req_b 就 commit，沒有「持續累積第三、第四筆 Request」的邏輯。N 個各自 1 人、
--      想找 N 人局的陌生人，永遠只會被拆成兩兩配對，且每組都會因為暫時人數=2而誤觸發
--      PENDING_CONFIRMATION（該流程設計給近似一對一場景，不是給大團體的暫時中間態）。
--   2. 舊版 commit_match 的 MATCHED vs PENDING_CONFIRMATION 分支純用 v_total>2（實際
--      撮合人數）判斷——判準本身沒錯，錯在舊演算法只能撮合到「暫時」人數，不代表真正
--      目標人數。這一輪修正的是演算法本身（讓 actual count 在 commit 當下確實可信），
--      沿用「實際累積人數」作為分支判準，不需要改成種子的靜態 min_participants 欄位
--      （曾評估過改用靜態欄位，但覆核後發現 array_length=2 不等於實際人數<=2——若
--      candidate 本身透過邀請連結已經是多人團，array_length 仍是 2 但實際人數可能
--      遠超過 2，此時繼續套用「近似一對一需要安全確認」的 PENDING_CONFIRMATION 流程
--      沒有意義，故最終維持「實際累積人數」判準，只是現在這個判準第一次變得可信）。
--   3. 額外發現的獨立 bug：舊版外層 for-loop 是 PL/pgSQL cursor，snapshot 在迴圈開始
--      時就固定，不會反映同一次函式執行中自己下的 UPDATE。若同組有 A/B/C/D 互相相容，
--      A 配 B 成 PENDING_CONFIRMATION 後，外層 cursor 仍會把 B 當作下一個 v_req_a
--      （因為它的固定列表還是舊的 REQUESTING 快照），導致 B 又被拿去跟 C 配對，同一筆
--      Request 出現在兩筆 pending_confirmation 裡。修法：改用「每次都重新 select 目前
--      仍是 REQUESTING 且本次執行還沒試過的最早一筆」的迴圈，而非固定快照的 cursor。
--
-- 新演算法（同組 = 同一個 (activity_type_id, school, campus)）：
--   - 種子 = 該組目前仍 REQUESTING、且本次執行還沒當過種子的最早一筆（live 查詢，
--     用 v_tried_seed_ids 陣列排除本次已處理過的種子，避免湊不滿時的無窮迴圈）
--   - 候選篩選：時間窗與目前累積集合有交集（N 方交集，每加入一個都重算整體上下界，
--     不是只跟種子比較）+ 與累積集合裡「每一個」owner 都沒有 match_history_avoidance
--     冷卻記錄（沿用既有 owner-only 慣例，不下探到 request_member）+ 候選自己的
--     [min_participants, max_participants] 跟種子的區間有重疊（存在至少一個雙方都能
--     接受的人數；殘留邊界情況——種子持續累積超過某候選原始預期的 max——記錄在
--     SPEC.md §16 開放問題，不在這輪解決）
--   - 累積達到種子 min_participants 且候選數 >= 2 即停止（貪婪達標）；候選若整筆併入
--     會讓總人數超過種子 max_participants，跳過該候選繼續看下一個（不整批停止掃描）
--   - 掃描完仍未達標：不做任何狀態變更，全部維持 REQUESTING，留到下次執行重新嘗試
--   - 成功時的分支：實際累積人數 >2 → 直接建立 Activity；否則（必然剛好 2 筆 Request，
--     見下方證明）→ 走 commit_match 的 pending_confirmation 分支
--
-- 證明「實際累積人數 <=2 時，累積集合必然剛好是 2 筆 Request」：
--   每筆 Request 至少有 owner 1 人，若累積了 >=3 筆 Request，實際人數必然 >=3，
--   矛盾於「實際人數<=2」的前提；而累積集合本來就規定至少要有種子以外 1 筆候選
--   （不變量：Activity 永遠由 >=2 筆獨立 Request 合併產生，見下方③），故實際人數
--   <=2 時集合大小恆為 2，可以安全傳給 commit_match(id1, id2) 這個二元相容介面。
--
-- 不變量（維持不變，不夾帶新功能）：
--   ③ 即使種子自己的既有成員數已達到/超過自己的 min_participants（例如透過邀請連結
--      已經湊滿的多人團），也不會單獨成局——仍然需要至少 1 筆外部候選才能轉成
--      Activity。這是現有架構本來就有的限制（join_request_by_token 從未在人數達標
--      時直接建立 Activity，一定要靠 Matching Engine），這輪不擴充。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. fn_create_activity_from_requests：簽章從 (uuid,uuid) 改成 (uuid[])，
--    支援 N 筆 Request 一次合併成一個 Activity。start_time 改成全體
--    earliest_start 取大（呼叫端已保證交集存在，這裡加一道防禦性檢查）。
--    新增 status 防禦性檢查：所有涉及 Request 必須是 REQUESTING 或
--    PENDING_CONFIRMATION（PC1 走這條路徑時已經是 PENDING_CONFIRMATION），
--    避免同一筆 Request 被重複處理（對應本輪新發現的 cursor bug 根因）。
-- -----------------------------------------------------------------------------
create or replace function fn_create_activity_from_requests(
  p_request_ids uuid[]
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity_type_id uuid;
  v_school           school;
  v_campus           text;
  v_start_time       timestamptz;
  v_latest_min       timestamptz;
  v_dur              int;
  v_activity         activity;
  v_found_count      int;
  v_bad_status_count int;
begin
  if p_request_ids is null or array_length(p_request_ids, 1) < 2 then
    raise exception using message = 'INVALID_INPUT', detail = 'AT_LEAST_TWO_REQUESTS_REQUIRED';
  end if;

  -- 鎖定全部涉及的 Request，原子處理
  perform 1 from match_request where id = any(p_request_ids) for update;

  select count(*) into v_found_count from match_request where id = any(p_request_ids);
  if v_found_count <> array_length(p_request_ids, 1) then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_bad_status_count
    from match_request
   where id = any(p_request_ids)
     and status not in ('REQUESTING', 'PENDING_CONFIRMATION');
  if v_bad_status_count > 0 then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  select activity_type_id, school, campus, max(earliest_start), min(latest_start)
    into v_activity_type_id, v_school, v_campus, v_start_time, v_latest_min
    from match_request
   where id = any(p_request_ids)
   group by activity_type_id, school, campus;

  if v_start_time > v_latest_min then
    -- 理論上呼叫端（fn_run_matching_engine 的 N 方交集檢查）已保證這裡恆成立，
    -- 這只是防禦性檢查，避免未來有新呼叫路徑繞過交集驗證
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_activity_type_id;

  insert into activity (
    activity_type_id, school, campus, start_time, estimated_end_time,
    status, contact_visible_until
  ) values (
    v_activity_type_id, v_school, v_campus,
    v_start_time, v_start_time + (v_dur || ' minutes')::interval,
    'MATCHED', now() + interval '24 hours'
  )
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity.id, rm.user_id, rm.request_id, 'JOINED'
    from request_member rm
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED';

  update match_request set status = 'MATCHED' where id = any(p_request_ids);

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
    from activity_member am where am.activity_id = v_activity.id;

  return v_activity;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. commit_match：簽章維持 (uuid,uuid)（相容介面，供 02/08 測試與 fn_run_matching_engine
--    的低人數分支直接呼叫），改呼叫新版 fn_create_activity_from_requests(array[...])，
--    新增 REQUESTING 狀態防禦性檢查（同樣對應 cursor bug 根因）。
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
  v_req_a match_request;
  v_req_b match_request;
  v_total int;
begin
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_req_a.status <> 'REQUESTING' or v_req_b.status <> 'REQUESTING' then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  select count(*) into v_total
    from request_member
   where request_id in (p_request_a_id, p_request_b_id) and status = 'JOINED';

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    return fn_create_activity_from_requests(array[p_request_a_id, p_request_b_id]);

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

-- -----------------------------------------------------------------------------
-- 3. fn_run_matching_engine：N 方累積演算法（見檔頭說明）
-- -----------------------------------------------------------------------------
create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group           record;
  v_seed            match_request;
  v_tried_seed_ids  uuid[];
  v_candidate       record;
  v_accum_ids       uuid[];
  v_accum_owner_ids uuid[];
  v_accum_count     int;
  v_accum_earliest  timestamptz;
  v_accum_latest    timestamptz;
  v_new_earliest    timestamptz;
  v_new_latest      timestamptz;
  v_cand_count      int;
  v_match_count     int := 0;
begin
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    v_tried_seed_ids := array[]::uuid[];

    loop
      -- live 重新挑「目前仍是 REQUESTING、本次執行還沒試過」中 created_at 最早的一筆
      -- 當種子——用全新 select（非 for-loop cursor）避免舊版的 snapshot 過期問題
      select * into v_seed
        from match_request
       where activity_type_id = v_group.activity_type_id
         and school = v_group.school
         and campus = v_group.campus
         and status = 'REQUESTING'
         and not (id = any(v_tried_seed_ids))
       order by created_at asc
       limit 1;

      exit when v_seed.id is null;

      v_tried_seed_ids := v_tried_seed_ids || v_seed.id;

      select count(*) into v_accum_count
        from request_member where request_id = v_seed.id and status = 'JOINED';

      v_accum_ids := array[v_seed.id];
      v_accum_owner_ids := array[v_seed.owner_id];
      v_accum_earliest := v_seed.earliest_start;
      v_accum_latest := v_seed.latest_start;

      for v_candidate in (
        select r.* from match_request r
         where r.activity_type_id = v_group.activity_type_id
           and r.school = v_group.school
           and r.campus = v_group.campus
           and r.status = 'REQUESTING'
           and r.id <> v_seed.id
           -- ①候選篩選：[候選 min,max] 跟 [種子 min,max] 存在至少一個雙方都能接受的
           -- 人數（null = 不設上限，視為 +∞）。殘留邊界情況見檔頭說明。
           and (v_seed.max_participants is null or r.min_participants <= v_seed.max_participants)
           and (r.max_participants is null or v_seed.min_participants <= r.max_participants)
         order by r.created_at asc
      ) loop
        exit when v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2;

        -- live 重新確認候選目前仍是 REQUESTING（防禦性；本次執行內不會有其他寫入
        -- 打斷同一個候選掃描，但保留這道檢查以防未來維護時引入例外）
        if not exists (select 1 from match_request where id = v_candidate.id and status = 'REQUESTING') then
          continue;
        end if;

        -- N 方時間窗交集：每加入一個候選都重算整體上下界，不是只跟種子比較
        v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
        v_new_latest := least(v_accum_latest, v_candidate.latest_start);
        if v_new_earliest > v_new_latest then
          continue; -- 加入這個候選會讓交集消失，跳過
        end if;

        -- avoidance 檢查：候選 owner 跟目前累積集合裡「每一個」owner 比對
        -- （owner-only，沿用既有 match_history_avoidance 的 pair 正規化慣例）
        if exists (
          select 1
            from unnest(v_accum_owner_ids) as ao(owner_id)
            join match_history_avoidance mha
              on mha.user_a_id = least(ao.owner_id, v_candidate.owner_id)
             and mha.user_b_id = greatest(ao.owner_id, v_candidate.owner_id)
             and mha.expire_at > now()
        ) then
          continue;
        end if;

        select count(*) into v_cand_count
          from request_member where request_id = v_candidate.id and status = 'JOINED';

        -- ②：候選整筆併入會超過種子 max_participants 就跳過，繼續看下一個候選
        -- （不整批停止掃描，可能還有更小的候選塞得下）
        if v_seed.max_participants is not null and v_accum_count + v_cand_count > v_seed.max_participants then
          continue;
        end if;

        v_accum_ids := v_accum_ids || v_candidate.id;
        v_accum_owner_ids := v_accum_owner_ids || v_candidate.owner_id;
        v_accum_count := v_accum_count + v_cand_count;
        v_accum_earliest := v_new_earliest;
        v_accum_latest := v_new_latest;
      end loop;

      if v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2 then
        -- 分支判準：實際累積人數（見檔頭「證明」，<=2 時集合必然剛好 2 筆 Request）
        if v_accum_count > 2 then
          perform fn_create_activity_from_requests(v_accum_ids);
        else
          perform commit_match(v_accum_ids[1], v_accum_ids[2]);
        end if;
        v_match_count := v_match_count + 1;
      end if;
      -- 否則：不做任何狀態變更，種子與所有候選維持 REQUESTING，留到下次執行重試
      -- （不變量③：即使種子已自足也不會單獨成局，見檔頭說明）
    end loop;
  end loop;

  return v_match_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. respond_pending_confirmation：PC1 呼叫點改用 array 版本的
--    fn_create_activity_from_requests（其餘邏輯不變，原封不動搬移）
-- -----------------------------------------------------------------------------
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

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
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
    perform fn_create_activity_from_requests(array[v_pc.request_a_id, v_pc.request_b_id]);
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- 不需要額外 grant execute：Postgres 對函式的 EXECUTE 預設就是 GRANT 給 PUBLIC
-- （見 20260724120800_grants.sql 的說明）。
