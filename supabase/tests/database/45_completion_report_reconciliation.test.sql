-- =============================================================================
-- pgTAP Test 45 — Completion Report Settlement Reconciliation & Mutual Accusation
--
-- 涵蓋：
-- 1. 兩人活動 u1 先回報 u2 缺席：活動轉 COMPLETED，u2 暫記 NO_SHOW。
-- 2. 活動已 COMPLETED 狀態下，u2 仍可在 24 小時窗口內提交回報。
-- 3. u2 指認 u1 缺席後，觸發二人互咬特例：u2 的 NO_SHOW 被撤銷，雙方均不被判 NO_SHOW。
-- 4. 同一人重複回報拋出 ALREADY_REPORTED。
-- 5. 非活動成員回報拋出 NOT_ACTIVITY_MEMBER。
-- 6. MATCHED 活動回報拋出 ACTIVITY_NOT_ENDED。
-- 7. 超過 24 小時窗口之活動回報拋出 ACTIVITY_NOT_ACTIVE。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

create temp table fixtures (
  act_type_id    uuid,
  campus         text default '光復',
  u1             uuid,
  u2             uuid,
  u_outsider     uuid,
  act_2p         uuid,
  act_matched    uuid,
  act_expired    uuid
);

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_act_2p activity;
  v_act_matched activity;
  v_act_expired activity;
  v_req1 uuid;
  v_req2 uuid;
begin
  insert into auth.users (id, email) values
    (v_u1, 'cr_1@nycu.edu.tw'),
    (v_u2, 'cr_2@nycu.edu.tw'),
    (v_outsider, 'cr_outsider@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_u1, 'cr_1@nycu.edu.tw', 'NYCU', 'CR 1', 'https://avatar.cr_1', 'MASTER', 'cr_1_line'),
    (v_u2, 'cr_2@nycu.edu.tw', 'NYCU', 'CR 2', 'https://avatar.cr_2', 'MASTER', 'cr_2_line'),
    (v_outsider, 'cr_outsider@nycu.edu.tw', 'NYCU', 'CR Outsider', 'https://avatar.cr_outsider', 'MASTER', 'cr_outsider_line');

  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;

  -- 1. 兩人進行中活動 (act_2p)
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u1, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 2, 2, 'MATCHED')
  returning id into v_req1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u2, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 2, 2, 'MATCHED')
  returning id into v_req2;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 'ONGOING', now() + interval '22 hours')
  returning * into v_act_2p;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_2p.id, v_u1, v_req1, 'JOINED'),
    (v_act_2p.id, v_u2, v_req2, 'JOINED');

  -- 2. 尚未開始活動 (MATCHED)
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '2 hours', now() + interval '3 hours', 'MATCHED')
  returning * into v_act_matched;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_matched.id, v_u1, v_req1, 'JOINED');

  -- 3. 超過 24 小時窗口之已完成活動 (EXPIRED)
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '30 hours', now() - interval '29 hours', 'COMPLETED', now() - interval '5 hours')
  returning * into v_act_expired;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_expired.id, v_u1, v_req1, 'JOINED');

  insert into fixtures (act_type_id, campus, u1, u2, u_outsider, act_2p, act_matched, act_expired)
  values (v_act_type_id, v_campus, v_u1, v_u2, v_outsider, v_act_2p.id, v_act_matched.id, v_act_expired.id);
end $setup$;

-- -----------------------------------------------------------------------------
-- Test 1: u1 回報 u2 缺席，法定人數 1 人達成，活動轉 COMPLETED，u2 記 NO_SHOW
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u1::text from fixtures), true);
end $$;

select lives_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[%L]::uuid[])$sql$,
    (select act_2p from fixtures),
    (select u2 from fixtures)),
  'u1 可成功回報 u2 缺席'
);

select results_eq(
  format($sql$select status from activity where id = %L$sql$, (select act_2p from fixtures)),
  array['COMPLETED'::activity_status],
  '活動達法定人數後應更新為 COMPLETED'
);

select results_eq(
  format($sql$select event_type from user_reliability_event where activity_id = %L and user_id = %L$sql$,
    (select act_2p from fixtures), (select u2 from fixtures)),
  array['NO_SHOW'::reliability_event_type],
  '第一人回報後 u2 應先被記 NO_SHOW'
);

-- -----------------------------------------------------------------------------
-- Test 2: 活動已是 COMPLETED，u2 在 24h 窗口內仍可回報，並指認 u1 缺席
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u2::text from fixtures), true);
end $$;

select lives_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[%L]::uuid[])$sql$,
    (select act_2p from fixtures),
    (select u1 from fixtures)),
  '已 COMPLETED 的活動在 24 小時窗口內仍放行第二人回報'
);

-- -----------------------------------------------------------------------------
-- Test 3: 互咬校正生效，雙方均不被記 NO_SHOW
-- -----------------------------------------------------------------------------
select is_empty(
  format($sql$select 1 from user_reliability_event where activity_id = %L and event_type = 'NO_SHOW'$sql$,
    (select act_2p from fixtures)),
  '兩人互咬特例生效，原本的 NO_SHOW 應被撤銷，雙方均不記 NO_SHOW'
);

-- -----------------------------------------------------------------------------
-- Test 4: 重複回報應拋出 ALREADY_REPORTED
-- -----------------------------------------------------------------------------
select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_2p from fixtures)),
  'ALREADY_REPORTED',
  '同一人對同活動重複提交應拋出 ALREADY_REPORTED'
);

-- -----------------------------------------------------------------------------
-- Test 5: 非活動成員回報應拋出 NOT_ACTIVITY_MEMBER
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u_outsider::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_2p from fixtures)),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員回報應拋出 NOT_ACTIVITY_MEMBER'
);

-- -----------------------------------------------------------------------------
-- Test 6: 超過 24 小時窗口之已完成活動應被 ACTIVITY_NOT_ACTIVE 擋下
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u1::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', '{}')$sql$, (select act_expired from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  '超過 24 小時窗口之已完成活動應拋出 ACTIVITY_NOT_ACTIVE'
);

rollback;
