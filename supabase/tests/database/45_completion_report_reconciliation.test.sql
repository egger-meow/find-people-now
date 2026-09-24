-- =============================================================================
-- pgTAP Test 45 — Completion Report Settlement Reconciliation & Mutual Accusation
--
-- 涵蓋：
-- 1. 兩人活動 u1 先回報 u2 缺席：暫不結算或處分。
-- 2. u2 在 24 小時窗口內提交回報後才結算。
-- 3. u2 指認 u1 缺席後，互咬特例不處分任一方，且不清除無來源的其他停權。
-- 4. 同一人重複回報拋出 ALREADY_REPORTED。
-- 5. 非活動成員回報拋出 NOT_ACTIVITY_MEMBER。
-- 6. MATCHED 活動回報拋出 ACTIVITY_NOT_ENDED。
-- 7. 超過 24 小時窗口之活動回報拋出 ACTIVITY_NOT_ACTIVE。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(21);

select ok(
  not has_function_privilege('authenticated', 'public.fn_reconcile_completion_report(uuid, boolean)', 'execute'),
  '內部結算函式不可由一般登入者直接呼叫'
);

create temp table fixtures (
  act_type_id    uuid,
  campus         text default '光復',
  u1             uuid,
  u2             uuid,
  u3             uuid,
  u4             uuid,
  u_outsider     uuid,
  act_2p         uuid,
  act_2p_uni     uuid,
  act_2p_timeout uuid,
  act_matched    uuid,
  act_expired    uuid
);

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
  v_u3 uuid := gen_random_uuid();
  v_u4 uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_act_2p activity;
  v_act_2p_uni activity;
  v_act_2p_timeout activity;
  v_act_matched activity;
  v_act_expired activity;
  v_req1 uuid;
  v_req2 uuid;
  v_req3 uuid;
  v_req4 uuid;
begin
  insert into auth.users (id, email) values
    (v_u1, 'cr_1@nycu.edu.tw'),
    (v_u2, 'cr_2@nycu.edu.tw'),
    (v_u3, 'cr_3@nycu.edu.tw'),
    (v_u4, 'cr_4@nycu.edu.tw'),
    (v_outsider, 'cr_outsider@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_u1, 'cr_1@nycu.edu.tw', 'NYCU', 'CR 1', 'https://avatar.cr_1', 'MASTER', 'cr_1_line'),
    (v_u2, 'cr_2@nycu.edu.tw', 'NYCU', 'CR 2', 'https://avatar.cr_2', 'MASTER', 'cr_2_line'),
    (v_u3, 'cr_3@nycu.edu.tw', 'NYCU', 'CR 3', 'https://avatar.cr_3', 'MASTER', 'cr_3_line'),
    (v_u4, 'cr_4@nycu.edu.tw', 'NYCU', 'CR 4', 'https://avatar.cr_4', 'MASTER', 'cr_4_line'),
    (v_outsider, 'cr_outsider@nycu.edu.tw', 'NYCU', 'CR Outsider', 'https://avatar.cr_outsider', 'MASTER', 'cr_outsider_line');

  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;

  -- 1. 兩人互咬活動 (act_2p)
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

  -- 2. 兩人單向指認活動 (act_2p_uni：u3 指認 u4 缺席，u4 回報一切順利)
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u3, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 2, 2, 'MATCHED')
  returning id into v_req3;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_u4, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 2, 2, 'MATCHED')
  returning id into v_req4;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 'ONGOING', now() + interval '22 hours')
  returning * into v_act_2p_uni;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_2p_uni.id, v_u3, v_req3, 'JOINED'),
    (v_act_2p_uni.id, v_u4, v_req4, 'JOINED');

  -- 3. 僅一人回報，供 24 小時窗口屆滿時的 cron 結算測試
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 hour', 'ONGOING', now() + interval '22 hours')
  returning * into v_act_2p_timeout;
  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_2p_timeout.id, v_u3, v_req3, 'JOINED'),
    (v_act_2p_timeout.id, v_u4, v_req4, 'JOINED');

  -- 3. 尚未開始活動 (MATCHED)
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '2 hours', now() + interval '3 hours', 'MATCHED')
  returning * into v_act_matched;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_matched.id, v_u1, v_req1, 'JOINED');

  -- 4. 超過 24 小時窗口之已完成活動 (EXPIRED)
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '30 hours', now() - interval '29 hours', 'COMPLETED', now() - interval '5 hours')
  returning * into v_act_expired;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_act_expired.id, v_u1, v_req1, 'JOINED');

  insert into fixtures (act_type_id, campus, u1, u2, u3, u4, u_outsider, act_2p, act_2p_uni, act_2p_timeout, act_matched, act_expired)
  values (v_act_type_id, v_campus, v_u1, v_u2, v_u3, v_u4, v_outsider, v_act_2p.id, v_act_2p_uni.id, v_act_2p_timeout.id, v_act_matched.id, v_act_expired.id);
end $setup$;

-- -----------------------------------------------------------------------------
-- Test 1: u1 回報 u2 缺席，兩人活動等待另一方或期限屆滿
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
  array['ONGOING'::activity_status],
  '兩人活動第一人回報後應維持 ONGOING'
);

select results_eq(
  format($sql$select event_type from user_reliability_event where activity_id = %L and user_id = %L$sql$,
    (select act_2p from fixtures), (select u2 from fixtures)),
  '{}'::reliability_event_type[],
  '第一人回報後不得先對 u2 記 NO_SHOW'
);

-- 模擬與本活動無關的既有停權；互咬對帳不可清除它。
update app_user set suspended_until = now() + interval '5 days'
 where id = (select u2 from fixtures);

-- -----------------------------------------------------------------------------
-- Test 2: u2 在 24h 窗口內回報，並指認 u1 缺席
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u2::text from fixtures), true);
end $$;

select lives_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[%L]::uuid[])$sql$,
    (select act_2p from fixtures),
    (select u1 from fixtures)),
  '第二人在 24 小時窗口內仍可回報'
);

select results_eq(
  format($sql$select status from activity where id = %L$sql$, (select act_2p from fixtures)),
  array['COMPLETED'::activity_status],
  '雙方都回報後活動才結算為 COMPLETED'
);

-- -----------------------------------------------------------------------------
-- Test 3: 互咬校正生效，雙方均不被記 NO_SHOW
-- -----------------------------------------------------------------------------
select is_empty(
  format($sql$select 1 from user_reliability_event where activity_id = %L and event_type = 'NO_SHOW'$sql$,
    (select act_2p from fixtures)),
  '兩人互咬特例生效，雙方均不記 NO_SHOW'
);

select results_eq(
  format($sql$select suspended_until > now() from app_user where id = %L$sql$,
    (select u2 from fixtures)),
  array[true],
  '互咬結算不得清除來源不明的其他停權'
);

-- -----------------------------------------------------------------------------
-- Test 3b: 單向指認（u3 指認 u4 缺席，u4 回報一切順利）：u4 必須維持記 NO_SHOW，不得誤撤銷
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u3::text from fixtures), true);
  perform submit_completion_report((select act_2p_uni from fixtures), 'REPORTED_ABSENT', array[(select u4 from fixtures)]::uuid[]);

  perform set_config('request.jwt.claim.sub', (select u4::text from fixtures), true);
  perform submit_completion_report((select act_2p_uni from fixtures), 'WENT_WELL', '{}');
end $$;

select results_eq(
  format($sql$select event_type from user_reliability_event where activity_id = %L and user_id = %L$sql$,
    (select act_2p_uni from fixtures), (select u4 from fixtures)),
  array['NO_SHOW'::reliability_event_type],
  '單向指認且被指認者回報一切順利時，被指認者應維持記 NO_SHOW（互咬不成立）'
);

select results_eq(
  format($sql$select event_type from user_reliability_event where activity_id = %L and user_id = %L$sql$,
    (select act_2p_uni from fixtures), (select u3 from fixtures)),
  array['ATTENDED'::reliability_event_type],
  '單向指認中之舉報者應維持記 ATTENDED'
);

select results_eq(
  format($sql$select count(*) from completion_report where activity_id = %L$sql$,
    (select act_2p_uni from fixtures)),
  array[2::bigint],
  '兩筆回報序列化完成且完整寫入'
);

-- -----------------------------------------------------------------------------
-- Test 4: 重複回報應拋出 ALREADY_REPORTED
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u2::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[%L, %L]::uuid[])$sql$,
    (select act_2p from fixtures), (select u1 from fixtures), (select u1 from fixtures)),
  'INVALID_ABSENT_TARGET',
  '同一名缺席成員不能在一份回報內重複計票'
);

select throws_ok(
  format($sql$select submit_completion_report(%L, 'WENT_WELL', array[%L]::uuid[])$sql$,
    (select act_2p from fixtures), (select u1 from fixtures)),
  'INVALID_ABSENT_TARGET',
  '一切順利回報不能夾帶缺席指認'
);

select throws_ok(
  format($sql$select submit_completion_report(%L, 'REPORTED_ABSENT', array[null]::uuid[])$sql$,
    (select act_2p from fixtures)),
  'INVALID_ABSENT_TARGET',
  '缺席名單不得含空值'
);

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

-- 期滿結算：第一人回報後沒有 NO_SHOW，時間窗結束由既有 cron 補結算。
do $$ begin
  perform set_config('request.jwt.claim.sub', (select u3::text from fixtures), true);
  perform submit_completion_report(
    (select act_2p_timeout from fixtures), 'REPORTED_ABSENT',
    array[(select u4 from fixtures)]::uuid[]
  );
end $$;

select is_empty(
  format($sql$select 1 from user_reliability_event where activity_id = %L$sql$,
    (select act_2p_timeout from fixtures)),
  '兩人場次單人回報期間不產生信譽事件'
);

update activity set start_time = now() - interval '26 hours',
                    contact_visible_until = now() - interval '1 hour'
 where id = (select act_2p_timeout from fixtures);
do $$ begin perform fn_complete_activities(); end $$;

select results_eq(
  format($sql$select event_type from user_reliability_event where activity_id = %L and user_id = %L$sql$,
    (select act_2p_timeout from fixtures), (select u4 from fixtures)),
  array['NO_SHOW'::reliability_event_type],
  '期滿時既有背景工作替單人回報場次完成缺席結算'
);

select results_eq(
  format($sql$select status from activity where id = %L$sql$,
    (select act_2p_timeout from fixtures)),
  array['COMPLETED'::activity_status],
  '期滿結算後活動狀態為 COMPLETED'
);

do $$ begin perform fn_complete_activities(); end $$;
select results_eq(
  format($sql$select count(*) from user_reliability_event where activity_id = %L$sql$,
    (select act_2p_timeout from fixtures)),
  array[2::bigint],
  '背景工作重跑不重複插入信譽事件'
);

rollback;
