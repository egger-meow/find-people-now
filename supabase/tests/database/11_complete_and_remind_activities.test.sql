-- =============================================================================
-- pgTAP Test — fn_complete_activities() / fn_remind_completions()
-- (docs/API.md §9「Activity 超時完成」A4 + 「結束提醒」，首次實作)
--
-- fn_complete_activities：涵蓋 start_time+24h 已過的 ONGOING → 強制 COMPLETED
-- （不做 No-show 判定、不發通知）；未達 24h 的 ONGOING 不受影響；已經是
-- COMPLETED 的（模擬 submit_completion_report 已達標）不重複處理。
--
-- fn_remind_completions：涵蓋 estimated_end_time 已過的 ONGOING → 發送
-- COMPLETE_CONFIRMATION；同一活動重跑一次不應重複發送（去重比照
-- fn_remind_missing_location_candidates 查 notification 表本身的既有模式）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(9);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  act_type_id  uuid,
  campus       text,
  user1_id     uuid, act1_id uuid,  -- ONGOING, start_time+24h 已過 → 應強制 COMPLETED
  user2_id     uuid, act2_id uuid,  -- ONGOING, start_time+24h 未到 → 不應被動
  user3_id     uuid, act3_id uuid,  -- 已是 COMPLETED（模擬正常結算已達標）→ 不重複處理
  user4_id     uuid, act4_id uuid   -- ONGOING, estimated_end_time 已過 → 應收到提醒
);
insert into fixtures default values;

do $setup$
declare
  v_user1 uuid := gen_random_uuid();
  v_user2 uuid := gen_random_uuid();
  v_user3 uuid := gen_random_uuid();
  v_user4 uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_act1 activity;
  v_act2 activity;
  v_act3 activity;
  v_act4 activity;
  v_req1 match_request;
  v_req2 match_request;
  v_req3 match_request;
  v_req4 match_request;
begin
  insert into auth.users (id, email) values
    (v_user1, 'ca_1@nycu.edu.tw'), (v_user2, 'ca_2@nycu.edu.tw'),
    (v_user3, 'ca_3@nycu.edu.tw'), (v_user4, 'ca_4@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_user1, 'ca_1@nycu.edu.tw', 'NYCU', 'Ca 1', 'https://avatar.ca_1', 'MASTER', 'ca_1_line'),
    (v_user2, 'ca_2@nycu.edu.tw', 'NYCU', 'Ca 2', 'https://avatar.ca_2', 'MASTER', 'ca_2_line'),
    (v_user3, 'ca_3@nycu.edu.tw', 'NYCU', 'Ca 3', 'https://avatar.ca_3', 'MASTER', 'ca_3_line'),
    (v_user4, 'ca_4@nycu.edu.tw', 'NYCU', 'Ca 4', 'https://avatar.ca_4', 'MASTER', 'ca_4_line');

  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '學生活動中心', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- activity_member.source_request_id 是 NOT NULL，每個 activity 各配一筆已 MATCHED
  -- 的 match_request 純粹只是滿足外鍵，不是這份測試的重點
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user1, v_act_type_id, 'NYCU', v_campus, now() - interval '26 hours', now() - interval '25 hours', 2, 2, 'MATCHED')
  returning * into v_req1;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user2, v_act_type_id, 'NYCU', v_campus, now() - interval '6 hours', now() - interval '5 hours', 2, 2, 'MATCHED')
  returning * into v_req2;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user3, v_act_type_id, 'NYCU', v_campus, now() - interval '31 hours', now() - interval '30 hours', 2, 2, 'MATCHED')
  returning * into v_req3;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user4, v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 2, 2, 'MATCHED')
  returning * into v_req4;

  -- act1: start_time 25 小時前，ONGOING，未達回報門檻 → fn_complete_activities 應強制 COMPLETED
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '25 hours', now() - interval '24 hours', 'ONGOING')
  returning * into v_act1;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act1.id, v_user1, v_req1.id, 'JOINED');

  -- act2: start_time 只有 5 小時前，ONGOING，還沒到 24h → 不應被動；estimated_end_time
  -- 特意設在未來，避免這筆也被 fn_remind_completions 撿到，維持這筆只測
  -- fn_complete_activities 邊界的單一目的
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '5 hours', now() + interval '1 hour', 'ONGOING')
  returning * into v_act2;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act2.id, v_user2, v_req2.id, 'JOINED');

  -- act3: start_time 30 小時前但已經是 COMPLETED（模擬 submit_completion_report 已經達標
  -- 結算過），兩條路徑天然互斥，這裡確認不會被重複處理出任何錯誤
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '30 hours', now() - interval '29 hours', 'COMPLETED')
  returning * into v_act3;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act3.id, v_user3, v_req3.id, 'JOINED');

  -- act4: estimated_end_time 已過 10 分鐘，ONGOING，還沒到 24h 強制門檻
  -- → fn_remind_completions 應發 COMPLETE_CONFIRMATION（fn_complete_activities 不應動它）
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '10 minutes', 'ONGOING')
  returning * into v_act4;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act4.id, v_user4, v_req4.id, 'JOINED');

  update fixtures set
    act_type_id = v_act_type_id, campus = v_campus,
    user1_id = v_user1, act1_id = v_act1.id,
    user2_id = v_user2, act2_id = v_act2.id,
    user3_id = v_user3, act3_id = v_act3.id,
    user4_id = v_user4, act4_id = v_act4.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- fn_complete_activities()
-- -----------------------------------------------------------------------------

select is(fn_complete_activities(), 1, 'fn_complete_activities 應恰好強制轉移 1 筆（act1）');

select is(
  (select status::text from activity where id = (select act1_id from fixtures)),
  'COMPLETED',
  'start_time+24h 已過且未達回報門檻的 ONGOING 應強制轉 COMPLETED'
);

select is(
  (select count(*)::int from user_reliability_event where activity_id = (select act1_id from fixtures)),
  0,
  'A4 強制完成不做任何 No-show 判定，不應寫入任何 user_reliability_event'
);

select is(
  (select status::text from activity where id = (select act2_id from fixtures)),
  'ONGOING',
  'start_time+24h 尚未到的 ONGOING 不應被動'
);

select is(
  (select status::text from activity where id = (select act3_id from fixtures)),
  'COMPLETED',
  '已經是 COMPLETED 的活動應保持不變（兩條路徑天然互斥，不重複處理）'
);

-- -----------------------------------------------------------------------------
-- fn_remind_completions()
-- -----------------------------------------------------------------------------

select is(fn_remind_completions(), 1, 'fn_remind_completions 應恰好處理 1 筆（act4）');

select is(
  (select count(*)::int from notification
    where event_type = 'COMPLETE_CONFIRMATION'
      and user_id = (select user4_id from fixtures)
      and (payload->>'activity_id')::uuid = (select act4_id from fixtures)),
  1,
  'estimated_end_time 已過的 ONGOING 活動應向全體 JOINED 成員發送 COMPLETE_CONFIRMATION'
);

-- 重跑一次應該去重，不再重複發送第二則
select is(fn_remind_completions(), 0, '重跑一次不應對同一活動重複發送，fn_remind_completions() 應回傳 0');

select is(
  (select count(*)::int from notification
    where event_type = 'COMPLETE_CONFIRMATION'
      and (payload->>'activity_id')::uuid = (select act4_id from fixtures)),
  1,
  '重跑後 act4 的 COMPLETE_CONFIRMATION 通知總數仍應是 1，沒有重複'
);

select * from finish();

rollback;
