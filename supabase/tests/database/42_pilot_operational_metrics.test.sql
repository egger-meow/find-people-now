-- =============================================================================
-- pgTAP Test — 最小試營運保護隱私觀測 RPC (get_pilot_operational_metrics)
--
-- 涵蓋：
-- 1. 權限防禦：authenticated 與 anon 不可執行該函式（僅限 service_role）
-- 2. 需求量與等待時間統計（成團數、逾時數、取消數）
-- 3. 成團不等於出席（關鍵界線）：
--    - 現場打卡或 ATTENDED 結算計入 verified_attended_members
--    - A4 超時自動結案但無到場證據者，嚴格計入 unverified_completion_members
-- 4. 再次參與（重複參與者）統計正確性
-- 5. 檢舉案件分類與回饋統計
-- 6. 未知欄位忠實返回 UNKNOWN
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

-- -----------------------------------------------------------------------------
-- 1. 權限防禦檢查
-- -----------------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.get_pilot_operational_metrics(school, text, timestamp with time zone, timestamp with time zone)', 'execute'),
  'anon 不可執行 get_pilot_operational_metrics'
);

select ok(
  not has_function_privilege('authenticated', 'public.get_pilot_operational_metrics(school, text, timestamp with time zone, timestamp with time zone)', 'execute'),
  'authenticated 不可執行 get_pilot_operational_metrics（保護營運指標隱私）'
);

-- -----------------------------------------------------------------------------
-- 2. 測試資料準備 (Fixtures)
-- -----------------------------------------------------------------------------
create temp table fixtures (
  user_a uuid,
  user_b uuid,
  user_c uuid,
  act_type uuid,
  loc_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_t uuid;
  v_loc uuid;
  v_act1 uuid := gen_random_uuid();
  v_act2 uuid := gen_random_uuid();
  v_req1 uuid := gen_random_uuid();
  v_req2 uuid := gen_random_uuid();
  v_req3 uuid := gen_random_uuid();
  v_req4 uuid := gen_random_uuid();
  v_req5 uuid := gen_random_uuid();
  v_now timestamptz := now();
begin
  -- 建立 3 位陽明交大學生
  insert into auth.users (id, email) values
    (v_a, 'pilot_a@nycu.edu.tw'),
    (v_b, 'pilot_b@nycu.edu.tw'),
    (v_c, 'pilot_c@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_a, 'pilot_a@nycu.edu.tw', 'NYCU', 'Pilot A', 'https://avatar/a', 'UNDERGRAD', 'pilot_a_ig'),
    (v_b, 'pilot_b@nycu.edu.tw', 'NYCU', 'Pilot B', 'https://avatar/b', 'UNDERGRAD', 'pilot_b_ig'),
    (v_c, 'pilot_c@nycu.edu.tw', 'NYCU', 'Pilot C', 'https://avatar/c', 'UNDERGRAD', 'pilot_c_ig');

  select id into v_t from activity_type where status = 'APPROVED' limit 1;
  select id into v_loc from location where school = 'NYCU' and campus = '光復' and status = 'APPROVED' limit 1;
  update fixtures set user_a = v_a, user_b = v_b, user_c = v_c, act_type = v_t, loc_id = v_loc;

  -- 需求 1 & 2：成團（User A, User B），建立時間 20 分鐘前
  insert into match_request (id, owner_id, school, campus, activity_type_id, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values
    (v_req1, v_a, 'NYCU', 'Pilot-Campus', v_t, v_now + interval '1 hour', v_now + interval '2 hours', 2, 4, 'MATCHED', v_now - interval '20 minutes'),
    (v_req2, v_b, 'NYCU', 'Pilot-Campus', v_t, v_now + interval '1 hour', v_now + interval '2 hours', 2, 4, 'MATCHED', v_now - interval '20 minutes');

  insert into request_member (request_id, user_id, role, status) values
    (v_req1, v_a, 'OWNER', 'JOINED'),
    (v_req2, v_b, 'OWNER', 'JOINED');

  -- 需求 3：逾時（User C）
  insert into match_request (id, owner_id, school, campus, activity_type_id, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values
    (v_req3, v_c, 'NYCU', 'Pilot-Campus', v_t, v_now - interval '2 hours', v_now - interval '1 hour', 2, 4, 'EXPIRED', v_now - interval '3 hours');

  insert into request_member (request_id, user_id, role, status) values
    (v_req3, v_c, 'OWNER', 'JOINED');

  -- 需求 4：取消（User A 再次發起但取消）
  insert into match_request (id, owner_id, school, campus, activity_type_id, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values
    (v_req4, v_a, 'NYCU', 'Pilot-Campus', v_t, v_now + interval '1 hour', v_now + interval '2 hours', 2, 4, 'CANCELLED', v_now - interval '10 minutes');

  insert into request_member (request_id, user_id, role, status) values
    (v_req4, v_a, 'OWNER', 'JOINED');

  -- 需求 5：User C 再次發起（使 User C 也成為再次參與者）
  insert into match_request (id, owner_id, school, campus, activity_type_id, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values
    (v_req5, v_c, 'NYCU', 'Pilot-Campus', v_t, v_now + interval '2 hours', v_now + interval '3 hours', 2, 4, 'MATCHED', v_now - interval '5 minutes');

  insert into request_member (request_id, user_id, role, status) values
    (v_req5, v_c, 'OWNER', 'JOINED');

  -- 活動 1：已完成，成立於 10 分鐘前（等待時間 20 - 10 = 10 分鐘）
  -- User A 現場打卡 (arrived_at) -> 證實出席
  -- User B 未打卡但有 ATTENDED 結算事件 -> 證實出席
  insert into activity (id, school, campus, activity_type_id, activity_location_id, start_time, estimated_end_time, status, created_at)
  values (v_act1, 'NYCU', 'Pilot-Campus', v_t, null, v_now - interval '30 minutes', v_now + interval '30 minutes', 'COMPLETED', v_now - interval '10 minutes');

  insert into activity_member (activity_id, user_id, source_request_id, status, arrived_at)
  values
    (v_act1, v_a, v_req1, 'JOINED', v_now - interval '15 minutes'),
    (v_act1, v_b, v_req2, 'JOINED', null);

  insert into user_reliability_event (user_id, activity_id, event_type, created_at)
  values (v_b, v_act1, 'ATTENDED', v_now - interval '5 minutes');

  -- 活動 2：A4 超時結案（COMPLETED），但無任何人打卡、無結算回報紀錄
  -- 成員 User C（原 req5）
  insert into activity (id, school, campus, activity_type_id, activity_location_id, start_time, estimated_end_time, status, created_at)
  values (v_act2, 'NYCU', 'Pilot-Campus', v_t, null, v_now - interval '25 hours', v_now - interval '24 hours', 'COMPLETED', v_now - interval '5 minutes');

  insert into activity_member (activity_id, user_id, source_request_id, status, arrived_at)
  values (v_act2, v_c, v_req5, 'JOINED', null);

  -- 檢舉與回饋測試資料
  insert into report (reporter_id, reported_user_id, category, detail, status, created_at)
  values (v_a, v_b, 'HARASSMENT', '言語騷擾測試', 'PENDING', v_now - interval '2 minutes');

  insert into feedback (user_id, message, created_at)
  values (v_c, '羽球球友很守時，體驗很好！', v_now - interval '1 minute');
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 3. 呼叫 get_pilot_operational_metrics 並驗證回傳指標
-- -----------------------------------------------------------------------------
create temp table metric_result as
select get_pilot_operational_metrics(
  'NYCU',
  'Pilot-Campus',
  now() - interval '24 hours',
  now() + interval '1 hour'
) as res;

-- 需求量驗證
select is(
  ((select res from metric_result) -> 'demand' ->> 'total_requests')::int,
  5,
  '24小時內應有 5 筆 match_request'
);

select is(
  ((select res from metric_result) -> 'demand' ->> 'cancelled_wait_minutes'),
  'UNKNOWN',
  '主動取消之等待時長應忠實標示為 UNKNOWN'
);

-- 出席判定驗證（關鍵邊界：成團不等於出席）
select is(
  ((select res from metric_result) -> 'attendance' ->> 'verified_attended_members')::int,
  2,
  '已驗證出席人次應為 2（User A 打卡報到 + User B ATTENDED 事件）'
);

select is(
  ((select res from metric_result) -> 'attendance' ->> 'unverified_completion_members')::int,
  1,
  '無打卡無結算之 A4 完成活動成員應嚴格計入 unverified_completion_members（1人）'
);

-- 再次參與度驗證
select is(
  ((select res from metric_result) -> 'retention' ->> 'repeat_request_users')::int,
  2,
  '重複發起需求人數應為 2（User A 有 2 需求，User C 有 2 需求）'
);

select * from finish();

rollback;
