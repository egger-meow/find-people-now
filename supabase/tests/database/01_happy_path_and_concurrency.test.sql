-- =============================================================================
-- pgTAP Test — Release Checklist (Backend Domain v1.0 + v1.7 硬化規則)
-- 涵蓋：Happy Path、Race Condition/並發寫入、Failure Cases 異常捕獲、
--       v1.7 ACTIVE_ACTIVITY_IN_PROGRESS / REQUEST_COOLDOWN_ACTIVE 及其檢查順序
--
-- 執行：`supabase test db`（預設掃描 supabase/tests/ 下所有 .sql/.pg 檔）
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(10);

-- -----------------------------------------------------------------------------
-- 0. Setup：建立測試用 Users / Location / ActivityType 等基礎資料
--    （所有 setup 動作放在 DO 區塊內，避免非斷言輸出混入 TAP 串流）
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_a_id     uuid,
  user_b_id     uuid,
  user_c_id     uuid,
  act_type_id   uuid,
  campus_nycu   text,
  campus_nthu   text,
  req_a_id      uuid,
  req_b_id      uuid,
  new_req_a_id  uuid,
  new_req_c_id  uuid
);
insert into fixtures default values;

do $setup$
declare
  v_user_a_id   uuid := gen_random_uuid();
  v_user_b_id   uuid := gen_random_uuid();
  v_user_c_id   uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus_nycu text := '光復';
  v_campus_nthu text := '校本部';
  v_req_a       match_request;
  v_req_b       match_request;
begin
  insert into auth.users (id, email) values
    (v_user_a_id, 'release_a@nycu.edu.tw'),
    (v_user_b_id, 'release_b@nycu.edu.tw'),
    (v_user_c_id, 'release_c@nthu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig, contact_line) values
    (v_user_a_id, 'release_a@nycu.edu.tw', 'NYCU', 'User A', 'https://avatar.a', 'MASTER', 'user_a_ig', 'user_a_line'),
    (v_user_b_id, 'release_b@nycu.edu.tw', 'NYCU', 'User B', 'https://avatar.b', 'PHD', 'user_b_ig', 'user_b_line'),
    (v_user_c_id, 'release_c@nthu.edu.tw', 'NTHU', 'User C', 'https://avatar.c', 'UNDERGRAD', 'user_c_ig', 'user_c_line');

  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  -- v1.11：location 新增 campus，Matching Scope 改成 (school, campus) 範圍匹配，
  -- 不再是精確地點 FK；這裡 seed 的兩筆地點分別是各自 campus 底下唯一的候選
  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus_nycu, '浩然圖書館前廣場', true),
    ('NTHU', v_campus_nthu, '風雲球場', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- User A / B 各自發起 籃球 (min 6, max 12)，直接寫入 REQUESTING 以重現既有撮合情境
  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_a_id, v_act_type_id, 'NYCU', v_campus_nycu,
    now(), now() + interval '2 hours', 6, 12, 'REQUESTING'
  ) returning * into v_req_a;

  insert into request_member (request_id, user_id, role, status)
  values (v_req_a.id, v_user_a_id, 'OWNER', 'JOINED');

  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_b_id, v_act_type_id, 'NYCU', v_campus_nycu,
    now(), now() + interval '2 hours', 6, 12, 'REQUESTING'
  ) returning * into v_req_b;

  insert into request_member (request_id, user_id, role, status)
  values (v_req_b.id, v_user_b_id, 'OWNER', 'JOINED');

  -- 模擬 4 名成員併入
  for i in 1..4 loop
    declare
      v_ex_id uuid := gen_random_uuid();
    begin
      insert into auth.users (id, email) values (v_ex_id, 'rel_ex_' || i || '@nycu.edu.tw');
      insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
      values (v_ex_id, 'rel_ex_' || i || '@nycu.edu.tw', 'NYCU', 'Ex ' || i, 'https://avatar.ex', 'UNDERGRAD', 'rel_ex_' || i || '_ig');
      insert into request_member (request_id, user_id, role, status)
      values (v_req_a.id, v_ex_id, 'MEMBER', 'JOINED');
    end;
  end loop;

  update fixtures set
    user_a_id   = v_user_a_id,
    user_b_id   = v_user_b_id,
    user_c_id   = v_user_c_id,
    act_type_id = v_act_type_id,
    campus_nycu = v_campus_nycu,
    campus_nthu = v_campus_nthu,
    req_a_id    = v_req_a.id,
    req_b_id    = v_req_b.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. Failure Cases：Matching Scope 範圍驗證 (INVALID_CAMPUS_SCOPE，v1.11)
--    改走真正的 create_request RPC（而非繞過校驗的 raw insert），
--    才能真的驗證 RPC 層是否正確拋出。v1.11 起 create_request 不再接受精確地點，
--    campus 存在性檢查失敗回 INVALID_CAMPUS_SCOPE，取代原本的 SCHOOL_LOCATION_MISMATCH
--    （該碼 v1.11 起僅用於 join_request_by_token 的跨校加入檢查，見 04 測試）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_a_id::text from fixtures), true);
end $$;

select throws_ok(
  format(
    $sql$select create_request(%L, %L, %L, %s, %s, %L)$sql$,
    (select act_type_id from fixtures),
    (select campus_nthu from fixtures),
    'NOW', 6, 12, false
  ),
  'INVALID_CAMPUS_SCOPE',
  'NYCU 學生對只存在於 NTHU 的 campus 發起請求應被拒絕 (INVALID_CAMPUS_SCOPE)'
);

-- -----------------------------------------------------------------------------
-- 2. Happy Path & 撮合流程
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 1, 'Greedy Matching 應撮合 1 次');

-- -----------------------------------------------------------------------------
-- 3. Race Condition & 重複撮合防禦
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 0, '再次執行不應重複撮合');

select ok(
  exists (
    select 1 from activity
     where school = 'NYCU'
       and campus = (select campus_nycu from fixtures)
       and status = 'MATCHED'
  ),
  '應成功建立 Activity'
);

-- -----------------------------------------------------------------------------
-- 4. PENDING_CONFIRMATION & 超時避雷清理
-- -----------------------------------------------------------------------------

do $$ begin
  insert into pending_confirmation (request_a_id, request_b_id, confirm_window_expire_at, status)
  values (
    (select req_a_id from fixtures),
    (select req_b_id from fixtures),
    now() - interval '1 minute',
    'PENDING'
  );
end $$;

select cmp_ok(fn_cleanup_pending_confirmations(), '>=', 1, '超時清理 Worker 應處理過期候選記錄');

select ok(
  exists (
    select 1 from match_history_avoidance
     where user_a_id = least((select user_a_id from fixtures), (select user_b_id from fixtures))
       and user_b_id = greatest((select user_a_id from fixtures), (select user_b_id from fixtures))
  ),
  '應寫入避雷降權記錄'
);

select is(
  (select count(*)::int from notification
    where event_type = 'MATCH_NOT_FORMED'
      and user_id in ((select user_a_id from fixtures), (select user_b_id from fixtures))),
  2,
  '超時清理應向雙方各發一則 MATCH_NOT_FORMED 無差別通知（不歸因）'
);

-- -----------------------------------------------------------------------------
-- 5. v1.7 新規則：ACTIVE_ACTIVITY_IN_PROGRESS / REQUEST_COOLDOWN_ACTIVE
--    以及兩者同時成立時的檢查順序 (SPEC §6.3)
-- -----------------------------------------------------------------------------

-- 5.1 User A 目前仍是一個 MATCHED Activity 的 JOINED 成員，
--     此時再送出新請求應被 submit_request 擋下 (排在冷卻檢查之前)
do $$
declare
  v_user_a_id uuid := (select user_a_id from fixtures);
  v_req       match_request;
begin
  perform set_config('request.jwt.claim.sub', v_user_a_id::text, true);
  v_req := create_request(
    (select act_type_id from fixtures),
    (select campus_nycu from fixtures),
    'NOW', 6, 12, false
  );
  update fixtures set new_req_a_id = v_req.id;
end $$;

select throws_ok(
  format($sql$select submit_request(%L)$sql$, (select new_req_a_id from fixtures)),
  'ACTIVE_ACTIVITY_IN_PROGRESS',
  'User A 仍在 MATCHED Activity 中，submit_request 應被 ACTIVE_ACTIVITY_IN_PROGRESS 擋下'
);

-- 5.2 User C 沒有進行中的活動，但被標記 30 分鐘冷卻 → submit_request 應被 REQUEST_COOLDOWN_ACTIVE 擋下
do $$
declare
  v_user_c_id uuid := (select user_c_id from fixtures);
  v_req       match_request;
begin
  update app_user set next_request_allowed_at = now() + interval '10 minutes' where id = v_user_c_id;

  perform set_config('request.jwt.claim.sub', v_user_c_id::text, true);
  v_req := create_request(
    (select act_type_id from fixtures),
    (select campus_nthu from fixtures),
    'NOW', 6, 12, false
  );
  update fixtures set new_req_c_id = v_req.id;
end $$;

select throws_ok(
  format($sql$select submit_request(%L)$sql$, (select new_req_c_id from fixtures)),
  'REQUEST_COOLDOWN_ACTIVE',
  'User C 處於 30 分鐘冷卻期間，submit_request 應被 REQUEST_COOLDOWN_ACTIVE 擋下'
);

-- 5.3 兩條規則同時成立時的順序證明：讓 User A 同時滿足
--     ① 名下有 MATCHED Activity（沿用 5.1 的狀態，未曾改變）
--     ② next_request_allowed_at 也還沒到期
--     submit_request 應回傳 ACTIVE_ACTIVITY_IN_PROGRESS，而不是 REQUEST_COOLDOWN_ACTIVE
--     （5.1 的 submit_request 呼叫在 ACTIVE_ACTIVITY_IN_PROGRESS 就已拋出例外，
--     PL/pgSQL exception block 會自動回滾該次呼叫的效果，故 new_req_a_id 仍是 DRAFT，可重複使用）
do $$ begin
  update app_user
     set next_request_allowed_at = now() + interval '10 minutes'
   where id = (select user_a_id from fixtures);

  perform set_config('request.jwt.claim.sub', (select user_a_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_request(%L)$sql$, (select new_req_a_id from fixtures)),
  'ACTIVE_ACTIVITY_IN_PROGRESS',
  '同時違反兩條 v1.7 規則時，submit_request 應優先回傳 ACTIVE_ACTIVITY_IN_PROGRESS（驗證檢查順序，非 REQUEST_COOLDOWN_ACTIVE）'
);

select * from finish();

rollback;
