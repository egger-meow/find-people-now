-- =============================================================================
-- 背景任務補齊（二）：API.md §9 八個背景任務裡此前完全沒有對應函式的四個
-- （Request 過期、Downgrade 超時、Activity 超時完成 A4、結束提醒），外加兩個既有
-- 函式缺漏的通知觸發點（respond_downgrade 的 DOWNGRADE_RESULT、
-- fn_cleanup_pending_confirmations 的「配對未成立」MATCH_NOT_FORMED）。
--
-- 比照既有 fn_run_matching_engine / fn_start_activities 等背景函式的慣例：這輪
-- 只做成 callable function，不掛 pg_cron.schedule——排程本身的落地維持現狀，
-- 是另一個獨立、目前刻意擱置的任務。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. fn_expire_requests (新，首次實作)：對應 API.md §9「Request 過期」R4 + Downgrade 發起
--
-- 掃描 status='REQUESTING' 且 latest_start < now() 的 Request。決策順序：
--   ① 若此 Request 自己的實際 JOINED 人數已經 >= min_participants（Matching Engine
--      這輪一直沒找到可以 merge 的對象，見 RPC_COVERAGE.md 的說明），R4 的定義
--      是「仍未達 min_participants」，這種列不屬於 R4，這輪不動它，留給未來評估。
--   ② 若這個 request_id 曾經建立過 downgrade_request（不論任何狀態）：
--      - 仍是 PENDING/APPROVED（正在詢問中或已核准待重新撮合）→ 不重複處理，
--        交給下面的 fn_expire_downgrades（PENDING 超時）或未來的撮合邏輯（APPROVED）收尾
--      - 已經是 REJECTED/TIMEOUT（問過一次、沒談成）→ 不再問第二次，直接 EXPIRED
--   ③ 從未問過，且 allow_downgrade=true、算出的 target_size 有效（見下）、
--      且 latest_start 過期還在一個 consent window 的寬限期內 → 建立 downgrade_request
--   ④ 其餘情況（allow_downgrade=false / target_size 不合法 / 已經過期太久）→ EXPIRED
--
-- target_size 算法：greatest(2, 目前實際 JOINED 人數)。呼應 SPEC §7 貪婪策略的精神——
-- 不發明一個武斷數字，直接問「現在實際到場的這幾個人，你們願不願意就這樣成局」；
-- downgrade_request.target_size 本身有 DB CHECK (target_size >= 2)，greatest(2, ...)
-- 自然處理「只有 owner 一人」的邊界；若原本 min_participants 已經是下限 2，算出的
-- target 不可能 < min_participants，會自然落入「不提供 downgrade」分支，不需要
-- 額外特判 SPEC §8「target_size 必須低於原 min_participants 才有意義」這條規則。
--
-- 時間窗判斷：now() - latest_start < fn_get_config_interval('downgrade_consent_window_minutes')。
-- SPEC §8 原文的語境是「排程搶在 latest_start 之前跑，剩餘時間 < 10 分鐘就不問」；
-- 這裡的掃描條件本身就是 latest_start < now()（deadline 已過），故改用「deadline
-- 過去多久」而非「距離未來還剩多少」：如果剛過期不久（在一個 consent window 的
-- 寬限期內），值得給一次機會；超過這個寬限期還沒被處理，視為錯過時機，不再重新評估。
--
-- EXPIRED 分支刻意不發通知：STATE_MACHINE.md 現有文字寫「發通知告知未成團」，但
-- 那是從未真正實作過的舊文件描述；EXPIRED 本身是「什麼都沒發生」的被動結果，不是
-- 需要打斷使用者的失敗事件，使用者下次查詢自己的 Request 狀態時自然會看到。這輪也
-- 沒有為此新增 notification_event_type 值的預算（只新增 MATCH_NOT_FORMED 一個），
-- STATE_MACHINE.md 對應文字這輪一併更新為明確記錄這個決定。
-- -----------------------------------------------------------------------------

create or replace function fn_expire_requests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req      record;
  v_joined   int;
  v_target   int;
  v_dg_id    uuid;
  v_window   interval;
  v_stale    boolean;
  v_count    int := 0;
begin
  select fn_get_config_interval('downgrade_consent_window_minutes') into v_window;

  for v_req in (
    select * from match_request
     where status = 'REQUESTING' and latest_start < now()
  ) loop
    select count(*) into v_joined
      from request_member where request_id = v_req.id and status = 'JOINED';

    -- ① 自給自足邊緣情況：不屬於 R4，不動它
    if v_joined >= v_req.min_participants then
      continue;
    end if;

    -- ② 是否曾經問過 downgrade
    select exists (
      select 1 from downgrade_request
       where request_id = v_req.id and status in ('PENDING', 'APPROVED')
    ) into v_stale;

    if v_stale then
      -- 正在詢問中或已核准，交給別的流程收尾，這裡不動
      continue;
    end if;

    if exists (select 1 from downgrade_request where request_id = v_req.id) then
      -- 曾經問過（REJECTED/TIMEOUT），不再問第二次
      update match_request set status = 'EXPIRED' where id = v_req.id;
      v_count := v_count + 1;
      continue;
    end if;

    -- ③④ 從未問過：決定要不要提供這一次機會
    v_target := greatest(2, v_joined);

    if v_req.allow_downgrade
       and v_target < v_req.min_participants
       and (now() - v_req.latest_start) < v_window
    then
      insert into downgrade_request (request_id, target_size, expire_at, status)
      values (v_req.id, v_target, now() + v_window, 'PENDING')
      returning id into v_dg_id;

      insert into downgrade_consent (downgrade_request_id, user_id)
      select v_dg_id, rm.user_id
        from request_member rm
       where rm.request_id = v_req.id and rm.status = 'JOINED';

      insert into notification (user_id, event_type, payload)
      select rm.user_id, 'DOWNGRADE_REQUEST',
             jsonb_build_object(
               'request_id', v_req.id, 'downgrade_request_id', v_dg_id, 'target_size', v_target
             )
        from request_member rm
       where rm.request_id = v_req.id and rm.status = 'JOINED';
    else
      update match_request set status = 'EXPIRED' where id = v_req.id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. fn_expire_downgrades (新，首次實作)：對應 API.md §9「Downgrade 超時」
--
-- 掃描 downgrade_request 裡 status='PENDING' 且 expire_at < now() 的記錄，轉
-- TIMEOUT（超時視為拒絕，SPEC §8）。match_request 全程沒離開過 REQUESTING
-- （STATE_MACHINE.md「Downgrade 子流程」：Downgrade 不改變 match_request.status），
-- 這裡不需要、也不應該去動它的狀態或門檻——它會在之後某次 fn_expire_requests 掃描
-- 時，因為「已存在 REJECTED/TIMEOUT 的 downgrade_request」而直接落到 EXPIRED
-- （見上方 fn_expire_requests 的第 ② 步）。
-- -----------------------------------------------------------------------------

create or replace function fn_expire_downgrades()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dg    record;
  v_count int := 0;
begin
  for v_dg in (
    select * from downgrade_request
     where status = 'PENDING' and expire_at < now()
  ) loop
    update downgrade_request set status = 'TIMEOUT' where id = v_dg.id;

    insert into notification (user_id, event_type, payload)
    select dc.user_id, 'DOWNGRADE_RESULT',
           jsonb_build_object(
             'request_id', v_dg.request_id, 'downgrade_request_id', v_dg.id,
             'status', 'TIMEOUT', 'target_size', v_dg.target_size
           )
      from downgrade_consent dc
     where dc.downgrade_request_id = v_dg.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. respond_downgrade：補上此前完全沒發過的 DOWNGRADE_RESULT 通知
--    （REJECTED 立即發；APPROVED 只在全員同意的那一刻發，部分 AGREE 不發，
--    比照 respond_pending_confirmation 只在最終 PC1/PC2 轉移時才通知的既有模式）
-- -----------------------------------------------------------------------------

create or replace function respond_downgrade(
  p_downgrade_request_id uuid,
  p_agree                 boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_dg         downgrade_request;
  v_consent    downgrade_consent;
  v_min        int;
  v_new_resp   downgrade_response;
  v_total      int;
  v_agreed     int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_dg from downgrade_request where id = p_downgrade_request_id for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'DOWNGRADE_REQUEST_NOT_FOUND';
  end if;

  -- 呼叫者必須是被詢問名單之一（downgrade_consent 的名單來源 = 建立時展開的
  -- request_member，見 init migration 的表註解）
  select * into v_consent
    from downgrade_consent
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_DOWNGRADE';
  end if;

  -- ERD 設計備註 21：target_size 必須低於原 min_participants，回應 RPC 也要應用層比對
  -- （不只建立時檢查一次），防止資料被非預期方式寫壞後還被回應 RPC 當合法狀態處理
  select min_participants into v_min from match_request where id = v_dg.request_id;
  if v_min is null or v_dg.target_size >= v_min then
    raise exception using message = 'INVALID_INPUT', detail = 'DOWNGRADE_TARGET_SIZE_NOT_BELOW_MIN_PARTICIPANTS';
  end if;

  -- 10 分鐘 CONSENT_WINDOW；超時 = 拒絕，Request 以原門檻回池（SPEC §8）——這裡只
  -- 擋「已經過期還想回應」，實際把 Request 留在原門檻是背景清理任務的職責（同
  -- fn_cleanup_pending_confirmations 的分工模式），不在本 RPC 內處理
  if v_dg.status <> 'PENDING' or v_dg.expire_at < now() then
    raise exception using message = 'CONSENT_WINDOW_CLOSED';
  end if;

  if v_consent.response <> 'NO_RESPONSE' then
    raise exception using message = 'ALREADY_RESPONDED';
  end if;

  v_new_resp := case when p_agree then 'AGREE'::downgrade_response else 'DISAGREE'::downgrade_response end;

  update downgrade_consent
     set response = v_new_resp, responded_at = now()
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id;

  if p_agree = false then
    -- 任一人 DISAGREE → 立即 REJECTED（STATE_MACHINE：「任一人 DISAGREE →
    -- downgrade_request → REJECTED，Request 以原 min/max_participants 留在池中」）
    update downgrade_request set status = 'REJECTED' where id = p_downgrade_request_id;

    insert into notification (user_id, event_type, payload)
    select dc.user_id, 'DOWNGRADE_RESULT',
           jsonb_build_object(
             'request_id', v_dg.request_id, 'downgrade_request_id', v_dg.id,
             'status', 'REJECTED', 'target_size', v_dg.target_size
           )
      from downgrade_consent dc
     where dc.downgrade_request_id = v_dg.id;
  else
    -- 全員 AGREE 才 APPROVED；重新以 target_size 撮合是 Matching Engine（§9）的
    -- 職責，本 RPC 只負責原子性的狀態轉移
    select count(*), count(*) filter (where response = 'AGREE')
      into v_total, v_agreed
      from downgrade_consent
     where downgrade_request_id = p_downgrade_request_id;

    if v_agreed = v_total then
      update downgrade_request set status = 'APPROVED' where id = p_downgrade_request_id;

      insert into notification (user_id, event_type, payload)
      select dc.user_id, 'DOWNGRADE_RESULT',
             jsonb_build_object(
               'request_id', v_dg.request_id, 'downgrade_request_id', v_dg.id,
               'status', 'APPROVED', 'target_size', v_dg.target_size
             )
        from downgrade_consent dc
       where dc.downgrade_request_id = v_dg.id;
    end if;
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. fn_complete_activities (新，首次實作)：對應 API.md §9「Activity 超時完成」A4
--
-- 不需要重新計算法定人數門檻：submit_completion_report 一旦達標，當下就已經在
-- 同一個 transaction 內把 status 轉成 COMPLETED（見
-- 20260724120600_rpc_completion_and_settlement.sql）。任何在這裡仍然是
-- status='ONGOING' 的列，必然是「尚未達標」，兩條路徑天然互斥，不會重複處理，
-- 這裡也不需要重算一次多數決。不做任何 No-show 判定、不記任何事件（未達法定人數
-- 不判任何人，見 SPEC §10/STATE_MACHINE A4），轉移本身是靜默的 fallback，不發通知。
-- -----------------------------------------------------------------------------

create or replace function fn_complete_activities()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  update activity
     set status = 'COMPLETED'
   where status = 'ONGOING'
     and start_time + interval '24 hours' < now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. fn_remind_completions (新，首次實作)：對應 API.md §9「結束提醒」
--
-- 去重比照 fn_remind_missing_location_candidates 的既有模式：查 notification 表
-- 本身有沒有發過同一活動同一事件，不額外存欄位（同 known_member_count/得票數不
-- 落地存欄位的既有原則）。
-- -----------------------------------------------------------------------------

create or replace function fn_remind_completions()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity record;
  v_count    int := 0;
begin
  for v_activity in (
    select a.* from activity a
     where a.status = 'ONGOING'
       and a.estimated_end_time < now()
       and not exists (
         select 1 from notification n
          where n.event_type = 'COMPLETE_CONFIRMATION'
            and (n.payload->>'activity_id')::uuid = a.id
       )
  ) loop
    insert into notification (user_id, event_type, payload)
    select am.user_id, 'COMPLETE_CONFIRMATION', jsonb_build_object('activity_id', v_activity.id)
      from activity_member am where am.activity_id = v_activity.id and am.status = 'JOINED';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. fn_cleanup_pending_confirmations：補上此前完全沒發過的「配對未成立」通知
--    (MATCH_NOT_FORMED)。不歸因原則同 PC1/PC2 的既有設計（ERD 備註 16）——payload
--    只帶收件者「自己」的 request_id，不透露對方是誰、是拒絕還是超時。
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

    -- 4. 向雙方發送無差別「配對未成立」通知（不暴露對方回應與超時原因）——
    --    只帶收件者自己的 request_id，兩筆通知內容不對稱地各自指向自己的 Request
    insert into notification (user_id, event_type, payload)
    values (v_pc.owner_a, 'MATCH_NOT_FORMED', jsonb_build_object('request_id', v_pc.request_a_id));

    insert into notification (user_id, event_type, payload)
    values (v_pc.owner_b, 'MATCH_NOT_FORMED', jsonb_build_object('request_id', v_pc.request_b_id));

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
