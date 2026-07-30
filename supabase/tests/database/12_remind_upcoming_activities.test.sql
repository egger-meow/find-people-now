-- =============================================================================
-- pgTAP Test — fn_remind_upcoming_activities()
-- (docs/API.md §9「活動開始前提前提醒」，首次實作)
--
-- app_config.activity_reminder_lead_minutes_list 預設 '{30,10}'（30 分鐘前 +
-- 10 分鐘前兩個時間點）。涵蓋：
--   ① 只落在較長時間點（30 分鐘）內的活動 → 只發一次 30 分鐘提醒
--   ② 同時落在兩個時間點（30 與 10 分鐘）內的活動 → 兩則提醒各自獨立觸發
--   ③ 兩個時間點都還沒到的活動 → 不發任何提醒
--   ④ 已經 ONGOING（不是 MATCHED）的活動 → 不受影響
--   ⑤ 重跑一次應該對同一個 (activity, lead_minutes) 去重，不重複發送
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
  user1_id     uuid, act1_id uuid,  -- start_time +25 分鐘 → 只落在 30 分鐘窗內
  user2_id     uuid, act2_id uuid,  -- start_time +8 分鐘 → 同時落在 30 與 10 分鐘窗內
  user3_id     uuid, act3_id uuid,  -- start_time +60 分鐘 → 兩個窗都還沒到
  user4_id     uuid, act4_id uuid   -- 已經 ONGOING → 不受影響
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
    (v_user1, 'ua_1@nycu.edu.tw'), (v_user2, 'ua_2@nycu.edu.tw'),
    (v_user3, 'ua_3@nycu.edu.tw'), (v_user4, 'ua_4@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_user1, 'ua_1@nycu.edu.tw', 'NYCU', 'Ua 1', 'https://avatar.ua_1', 'MASTER', 'ua_1_line'),
    (v_user2, 'ua_2@nycu.edu.tw', 'NYCU', 'Ua 2', 'https://avatar.ua_2', 'MASTER', 'ua_2_line'),
    (v_user3, 'ua_3@nycu.edu.tw', 'NYCU', 'Ua 3', 'https://avatar.ua_3', 'MASTER', 'ua_3_line'),
    (v_user4, 'ua_4@nycu.edu.tw', 'NYCU', 'Ua 4', 'https://avatar.ua_4', 'MASTER', 'ua_4_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '學生活動中心', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- activity_member.source_request_id 是 NOT NULL，每個 activity 各配一筆已 MATCHED
  -- 的 match_request 純粹只是滿足外鍵，不是這份測試的重點
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '1 hour', 2, 2, 'MATCHED')
  returning * into v_req1;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user2, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '1 hour', 2, 2, 'MATCHED')
  returning * into v_req2;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user3, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '1 hour', 2, 2, 'MATCHED')
  returning * into v_req3;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user4, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 2, 2, 'MATCHED')
  returning * into v_req4;

  -- act1: start_time 25 分鐘後，只應觸發 30 分鐘提醒（10 分鐘窗還沒到）
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '25 minutes', now() + interval '85 minutes', 'MATCHED')
  returning * into v_act1;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act1.id, v_user1, v_req1.id, 'JOINED');

  -- act2: start_time 8 分鐘後，同時落在 30 分鐘與 10 分鐘兩個窗內，應各自觸發一次
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '8 minutes', now() + interval '68 minutes', 'MATCHED')
  returning * into v_act2;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act2.id, v_user2, v_req2.id, 'JOINED');

  -- act3: start_time 60 分鐘後，兩個窗都還沒到，不應觸發任何提醒
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '60 minutes', now() + interval '120 minutes', 'MATCHED')
  returning * into v_act3;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act3.id, v_user3, v_req3.id, 'JOINED');

  -- act4: 已經 ONGOING（不是 MATCHED），即使 start_time 早已落在提醒窗內範圍附近也不應被動
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '1 hour', now() + interval '1 hour', 'ONGOING')
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
-- 第一次執行 fn_remind_upcoming_activities()
-- -----------------------------------------------------------------------------

select is(
  fn_remind_upcoming_activities(), 3,
  'act1(30分鐘) + act2(30分鐘) + act2(10分鐘) 共 3 筆 (activity, lead_minutes) 組合應被處理'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act1_id from fixtures)
      and (payload->>'lead_minutes')::int = 30),
  1,
  'act1 應收到恰好一則 30 分鐘提醒'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act1_id from fixtures)
      and (payload->>'lead_minutes')::int = 10),
  0,
  'act1 尚未落入 10 分鐘窗，不應收到 10 分鐘提醒'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act2_id from fixtures)
      and (payload->>'lead_minutes')::int = 30),
  1,
  'act2 同時落在 30 分鐘窗內，應收到 30 分鐘提醒'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act2_id from fixtures)
      and (payload->>'lead_minutes')::int = 10),
  1,
  'act2 同時落在 10 分鐘窗內，應收到 10 分鐘提醒'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act3_id from fixtures)),
  0,
  'act3 兩個時間點都還沒到，不應收到任何提醒'
);

select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid = (select act4_id from fixtures)),
  0,
  'act4 已經 ONGOING（非 MATCHED），不應被 fn_remind_upcoming_activities 動到'
);

-- 重跑一次應該去重，不再重複發送
select is(
  fn_remind_upcoming_activities(), 0,
  '重跑一次不應對同一個 (activity, lead_minutes) 重複發送，應回傳 0'
);

-- 反饋（2026-07-30 supabase test db 重跑發現）：這裡原本是全表 count(*)，不像
-- 上面每一則都有 scope 到自己的 activity_id。20260724125500_
-- schedule_background_jobs.sql 把 fn_remind_upcoming_activities() 掛上
-- pg_cron 之後，本機資料庫裡累積的其他真實活動（來自其他 flutter test 檔案
-- 的 fixture）只要 start_time 剛好落進提醒窗，背景 cron 就會真的插入額外的
-- ACTIVITY_UPCOMING 列，讓這個全表 count 混進本測試 fixtures 以外的資料而
-- 失敗——跟其餘七則斷言一樣 scope 到本測試自己的四個 fixture activity_id。
select is(
  (select count(*)::int from notification
    where event_type = 'ACTIVITY_UPCOMING'
      and (payload->>'activity_id')::uuid in (
        select act1_id from fixtures union all
        select act2_id from fixtures union all
        select act3_id from fixtures union all
        select act4_id from fixtures
      )),
  3,
  '重跑後 ACTIVITY_UPCOMING 通知總數仍應是 3，沒有重複'
);

select * from finish();

rollback;
