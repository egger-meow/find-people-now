-- =============================================================================
-- pgTAP Test — cancel_activity_participation / submit_completion_report
-- validation gaps closed in 20260724122800_fix_activity_validation_gaps.sql
-- (see app/lib/rpc/RPC_COVERAGE.md "Error codes documented in API.md but
-- never raised" — ACTIVITY_ALREADY_ENDED/ACTIVITY_NOT_ENDED/INVALID_ABSENT_TARGET)
--
-- 涵蓋：
-- 1. cancel_activity_participation 對 COMPLETED/CANCELLED 活動應被
--    ACTIVITY_NOT_ACTIVE 擋下（STATE_MACHINE A5/A6 只允許 MATCHED/ONGOING）。
-- 2. submit_completion_report 對 MATCHED（還沒開始）/COMPLETED/CANCELLED
--    活動應被 ACTIVITY_NOT_ENDED 擋下（只有 ONGOING 才能提交完成回報）。
-- 3. submit_completion_report 的 absent_user_ids 內若含非活動成員應被
--    INVALID_ABSENT_TARGET 擋下，且該次呼叫不應留下任何 completion_report 記錄。
-- 4. 迴歸：ONGOING 活動 + 合法 absent_user_ids 仍應正常提交成功。
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
  act_type_id   uuid,
  campus        text,
  u_completed   uuid, act_completed  uuid,  -- COMPLETED，member 呼叫 cancel 應被擋
  u_cancelled   uuid, act_cancelled  uuid,  -- CANCELLED，member 呼叫 cancel 應被擋
  u_not_started uuid, act_not_started uuid, -- MATCHED（還沒開始），member 呼叫 submit_completion_report 應被擋
  u_report_completed uuid, act_report_completed uuid, -- COMPLETED，member 呼叫 submit_completion_report 應被擋
  u_report_cancelled uuid, act_report_cancelled uuid, -- CANCELLED，member 呼叫 submit_completion_report 應被擋
  u_ongoing_a   uuid,
  u_ongoing_b   uuid,
  act_ongoing   uuid,   -- ONGOING，2 位成員，測 INVALID_ABSENT_TARGET + 合法提交迴歸
  outsider_id   uuid    -- 完全不是 act_ongoing 的成員，用來當非法 absent target
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
  v_u3 uuid := gen_random_uuid();
  v_u4 uuid := gen_random_uuid();
  v_u5 uuid := gen_random_uuid();
  v_u6 uuid := gen_random_uuid();
  v_u7 uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_act1 activity; v_act2 activity; v_act3 activity;
  v_act4 activity; v_act5 activity; v_act6 activity;
  v_req_id uuid;
begin
  insert into auth.users (id, email) values
    (v_u1, 'avg_1@nycu.edu.tw'), (v_u2, 'avg_2@nycu.edu.tw'), (v_u3, 'avg_3@nycu.edu.tw'),
    (v_u4, 'avg_4@nycu.edu.tw'), (v_u5, 'avg_5@nycu.edu.tw'), (v_u6, 'avg_6@nycu.edu.tw'),
    (v_u7, 'avg_7@nycu.edu.tw'), (v_outsider, 'avg_outsider@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_u1, 'avg_1@nycu.edu.tw', 'NYCU', 'Avg 1', 'https://avatar.avg_1', 'MASTER', 'avg_1_line'),
    (v_u2, 'avg_2@nycu.edu.tw', 'NYCU', 'Avg 2', 'https://avatar.avg_2', 'MASTER', 'avg_2_line'),
    (v_u3, 'avg_3@nycu.edu.tw', 'NYCU', 'Avg 3', 'https://avatar.avg_3', 'MASTER', 'avg_3_line'),
    (v_u4, 'avg_4@nycu.edu.tw', 'NYCU', 'Avg 4', 'https://avatar.avg_4', 'MASTER', 'avg_4_line'),
    (v_u5, 'avg_5@nycu.edu.tw', 'NYCU', 'Avg 5', 'https://avatar.avg_5', 'MASTER', 'avg_5_line'),
    (v_u6, 'avg_6@nycu.edu.tw', 'NYCU', 'Avg 6', 'https://avatar.avg_6', 'MASTER', 'avg_6_line'),
    (v_u7, 'avg_7@nycu.edu.tw', 'NYCU', 'Avg 7', 'https://avatar.avg_7', 'MASTER', 'avg_7_line'),
    (v_outsider, 'avg_outsider@nycu.edu.tw', 'NYCU', 'Avg Outsider', 'https://avatar.avg_outsider', 'MASTER', 'avg_outsider_line');

  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '學生活動中心', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- act1：COMPLETED，u1 呼叫 cancel_activity_participation 應被 ACTIVITY_NOT_ACTIVE 擋下
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u1, v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
  returning * into v_act1;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act1.id, v_u1, v_req_id, 'JOINED');

  -- act2：CANCELLED，u2 呼叫 cancel_activity_participation 應被 ACTIVITY_NOT_ACTIVE 擋下
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u2, v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'CANCELLED')
  returning * into v_act2;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act2.id, v_u2, v_req_id, 'JOINED');

  -- act3：MATCHED，還沒開始，u3 呼叫 submit_completion_report 應被 ACTIVITY_NOT_ENDED 擋下
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u3, v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_act3;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act3.id, v_u3, v_req_id, 'JOINED');

  -- act4：COMPLETED，u4 呼叫 submit_completion_report 應被 ACTIVITY_NOT_ENDED 擋下
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u4, v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
  returning * into v_act4;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act4.id, v_u4, v_req_id, 'JOINED');

  -- act5：CANCELLED，u5 呼叫 submit_completion_report 應被 ACTIVITY_NOT_ENDED 擋下
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u5, v_act_type_id, 'NYCU', v_campus, now() - interval '1 hour', now(), 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '1 hour', now(), 'CANCELLED')
  returning * into v_act5;
  insert into activity_member (activity_id, user_id, source_request_id, status) values (v_act5.id, v_u5, v_req_id, 'JOINED');

  -- act6：ONGOING，u6/u7 兩位成員，測 INVALID_ABSENT_TARGET + 合法提交迴歸
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u6, v_act_type_id, 'NYCU', v_campus, now() - interval '1 hour', now(), 2, 2, 'MATCHED')
  returning id into v_req_id;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '1 hour', now() + interval '1 hour', 'ONGOING')
  returning * into v_act6;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_act6.id, u, v_req_id, 'JOINED' from unnest(array[v_u6, v_u7]) as u;

  update fixtures set
    act_type_id = v_act_type_id, campus = v_campus,
    u_completed = v_u1, act_completed = v_act1.id,
    u_cancelled = v_u2, act_cancelled = v_act2.id,
    u_not_started = v_u3, act_not_started = v_act3.id,
    u_report_completed = v_u4, act_report_completed = v_act4.id,
    u_report_cancelled = v_u5, act_report_cancelled = v_act5.id,
    u_ongoing_a = v_u6, u_ongoing_b = v_u7, act_ongoing = v_act6.id,
    outsider_id = v_outsider;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. cancel_activity_participation 對 COMPLETED 活動應被 ACTIVITY_NOT_ACTIVE 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_completed::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select cancel_activity_participation(%L)$sql$, (select act_completed from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  'cancel_activity_participation 對 COMPLETED 活動應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. cancel_activity_participation 對 CANCELLED 活動應被 ACTIVITY_NOT_ACTIVE 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_cancelled::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select cancel_activity_participation(%L)$sql$, (select act_cancelled from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  'cancel_activity_participation 對 CANCELLED 活動應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 3. submit_completion_report 對還沒開始（MATCHED）的活動應被 ACTIVITY_NOT_ENDED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_not_started::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_not_started from fixtures)),
  'ACTIVITY_NOT_ENDED',
  'submit_completion_report 對還沒開始的 MATCHED 活動應被 ACTIVITY_NOT_ENDED 擋下'
);

-- -----------------------------------------------------------------------------
-- 4. submit_completion_report 對已 COMPLETED 的活動應被 ACTIVITY_NOT_ENDED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_report_completed::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_report_completed from fixtures)),
  'ACTIVITY_NOT_ENDED',
  'submit_completion_report 對已 COMPLETED 的活動應被 ACTIVITY_NOT_ENDED 擋下'
);

-- -----------------------------------------------------------------------------
-- 5. submit_completion_report 對已 CANCELLED 的活動應被 ACTIVITY_NOT_ENDED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_report_cancelled::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_report_cancelled from fixtures)),
  'ACTIVITY_NOT_ENDED',
  'submit_completion_report 對已 CANCELLED 的活動應被 ACTIVITY_NOT_ENDED 擋下'
);

-- -----------------------------------------------------------------------------
-- 6. submit_completion_report 的 absent_user_ids 含非活動成員應被 INVALID_ABSENT_TARGET 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_ongoing_a::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[%L]::uuid[])$sql$,
    (select act_ongoing from fixtures), (select outsider_id from fixtures)),
  'INVALID_ABSENT_TARGET',
  'absent_user_ids 內含非活動成員應被 INVALID_ABSENT_TARGET 擋下'
);

select is(
  (select count(*)::int from completion_report where activity_id = (select act_ongoing from fixtures)),
  0,
  'INVALID_ABSENT_TARGET 擋下的呼叫不應留下任何 completion_report 記錄'
);

-- -----------------------------------------------------------------------------
-- 7. 迴歸：ONGOING 活動 + 合法 absent_user_ids（真正的活動成員）應正常提交成功
-- -----------------------------------------------------------------------------

select is(
  (select (submit_completion_report(
    (select act_ongoing from fixtures), 'REPORTED_ABSENT', array[(select u_ongoing_b::uuid from fixtures)]
  ))->>'success'),
  'true',
  'ONGOING 活動 + 合法 absent_user_ids（真正的成員）應正常提交成功'
);

select is(
  (select count(*)::int from completion_report
    where activity_id = (select act_ongoing from fixtures) and reporter_id = (select u_ongoing_a from fixtures)),
  1,
  '合法提交後應留下一筆 completion_report 記錄'
);

select * from finish();

rollback;
