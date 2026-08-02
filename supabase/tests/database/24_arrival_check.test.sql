-- =============================================================================
-- pgTAP Test — Arrival Check「我到了」(docs/API.md §6.8, SPEC v1.24)
-- 涵蓋：NOT_ACTIVITY_MEMBER、成功標記（單向覆寫 arrived_at）、冪等（重複呼叫
-- 不變更、不重複通知）、通知只發給「其餘」JOINED 成員（不含自己）、
-- COMPLETED/CANCELLED 邊界（不可再標記）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(11);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  m1_id           uuid,  -- activity_1 (MATCHED) member
  m2_id           uuid,  -- activity_1 (MATCHED) member
  outsider_id     uuid,
  c1_id           uuid,  -- activity_2 (COMPLETED) member
  x1_id           uuid,  -- activity_3 (CANCELLED) member
  deleted_id      uuid,  -- activity_1 member，帳號已刪除
  act_type_id     uuid,
  campus          text,
  activity1_id    uuid,
  activity2_id    uuid,
  activity3_id    uuid
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_m1        uuid := gen_random_uuid();
  v_m2        uuid := gen_random_uuid();
  v_outsider  uuid := gen_random_uuid();
  v_c1        uuid := gen_random_uuid();
  v_x1        uuid := gen_random_uuid();
  v_deleted   uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_req1        uuid;
  v_req2        uuid;
  v_req3        uuid;
  v_activity1   activity;
  v_activity2   activity;
  v_activity3   activity;
begin
  insert into auth.users (id, email) values
    (v_m1, 'ac_m1@nycu.edu.tw'), (v_m2, 'ac_m2@nycu.edu.tw'),
    (v_outsider, 'ac_outsider@nycu.edu.tw'),
    (v_c1, 'ac_c1@nycu.edu.tw'), (v_x1, 'ac_x1@nycu.edu.tw'),
    (v_deleted, 'ac_deleted@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_m1, 'ac_m1@nycu.edu.tw', 'NYCU', 'Ac M1', 'https://avatar.ac_m1', 'MASTER', 'ac_m1_line'),
    (v_m2, 'ac_m2@nycu.edu.tw', 'NYCU', 'Ac M2', 'https://avatar.ac_m2', 'MASTER', 'ac_m2_line'),
    (v_outsider, 'ac_outsider@nycu.edu.tw', 'NYCU', 'Ac Outsider', 'https://avatar.ac_outsider', 'MASTER', 'ac_outsider_line'),
    (v_c1, 'ac_c1@nycu.edu.tw', 'NYCU', 'Ac C1', 'https://avatar.ac_c1', 'MASTER', 'ac_c1_line'),
    (v_x1, 'ac_x1@nycu.edu.tw', 'NYCU', 'Ac X1', 'https://avatar.ac_x1', 'MASTER', 'ac_x1_line'),
    (v_deleted, 'ac_deleted@nycu.edu.tw', 'NYCU', 'Ac Deleted', 'https://avatar.ac_deleted', 'MASTER', 'ac_deleted_line');

  -- 比照 delete_account() 實際去識別化後的狀態，不直接偽造成一筆一開始就是
  -- deleted 的 row（會撞上 school_matches_email 之類的 CHECK 在插入當下還沒有
  -- deleted_at 短路條件可用）。
  update app_user
     set email = 'deleted+' || v_deleted::text, deleted_at = now()
   where id = v_deleted;

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_c1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req2;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_x1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req3;

  -- activity_1：MATCHED，2 位成員，主要 happy-path / 冪等 / 通知測試
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity1;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity1.id, u, v_req1, 'JOINED' from unnest(array[v_m1, v_m2, v_deleted]) as u;

  -- activity_2：COMPLETED，測邊界
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 'COMPLETED')
  returning * into v_activity2;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity2.id, v_c1, v_req2, 'JOINED');

  -- activity_3：CANCELLED，測邊界
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'CANCELLED')
  returning * into v_activity3;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity3.id, v_x1, v_req3, 'JOINED');

  update fixtures set
    m1_id = v_m1, m2_id = v_m2, outsider_id = v_outsider, c1_id = v_c1, x1_id = v_x1,
    deleted_id = v_deleted,
    act_type_id = v_act_type_id, campus = v_campus,
    activity1_id = v_activity1.id, activity2_id = v_activity2.id, activity3_id = v_activity3.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 非活動成員呼叫 mark_arrived 應被 NOT_ACTIVITY_MEMBER 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select mark_arrived(%L)$sql$, (select activity1_id from fixtures)),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員呼叫 mark_arrived 應被 NOT_ACTIVITY_MEMBER 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. m1 成功標記抵達
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
  perform mark_arrived((select activity1_id from fixtures));
end $$;

select isnt(
  (select arrived_at from activity_member
    where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures)),
  null,
  'm1 成功標記抵達後 arrived_at 應非 null'
);

-- -----------------------------------------------------------------------------
-- 3. m2（另一位成員）應收到 1 則 MEMBER_ARRIVED 通知，payload 帶正確資訊
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from notification
    where user_id = (select m2_id from fixtures)
      and event_type = 'MEMBER_ARRIVED'
      and (payload->>'activity_id')::uuid = (select activity1_id from fixtures)
      and (payload->>'arrived_user_id')::uuid = (select m1_id from fixtures)
      and payload->>'display_name' = 'Ac M1'),
  1,
  'm2 應收到 1 則 MEMBER_ARRIVED 通知，payload 帶正確的 arrived_user_id/display_name'
);

-- -----------------------------------------------------------------------------
-- 4. m1 自己不應收到自我抵達的通知
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from notification
    where user_id = (select m1_id from fixtures) and event_type = 'MEMBER_ARRIVED'),
  0,
  '抵達者本人不應收到自己的 MEMBER_ARRIVED 通知'
);

-- -----------------------------------------------------------------------------
-- 5. m1 重複呼叫 mark_arrived 應冪等：arrived_at 不變、不重複通知
-- -----------------------------------------------------------------------------

do $$
declare
  v_first_arrived_at timestamptz;
begin
  select arrived_at into v_first_arrived_at from activity_member
   where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures);

  perform pg_sleep(0.01);
  perform mark_arrived((select activity1_id from fixtures));

  if (select arrived_at from activity_member
       where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures))
     != v_first_arrived_at then
    raise exception 'arrived_at changed on repeat call, expected idempotent no-op';
  end if;
end $$;

select is(
  (select count(*)::int from notification
    where user_id = (select m2_id from fixtures)
      and event_type = 'MEMBER_ARRIVED'
      and (payload->>'activity_id')::uuid = (select activity1_id from fixtures)),
  1,
  '重複呼叫 mark_arrived 應冪等，不應再發第二則通知給 m2'
);

select ok(true, 'm1 重複呼叫 mark_arrived 後 arrived_at 應維持不變（上面的 do block 已驗證，未拋錯即通過）');

-- -----------------------------------------------------------------------------
-- 6. m2 標記抵達後，m1 應收到 1 則（換 m1 是接收方）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m2_id::text from fixtures), true);
  perform mark_arrived((select activity1_id from fixtures));
end $$;

select is(
  (select count(*)::int from notification
    where user_id = (select m1_id from fixtures)
      and event_type = 'MEMBER_ARRIVED'
      and (payload->>'arrived_user_id')::uuid = (select m2_id from fixtures)),
  1,
  'm2 標記抵達後，m1 應收到對應的 MEMBER_ARRIVED 通知'
);

-- -----------------------------------------------------------------------------
-- 7. 邊界：COMPLETED 的活動不可再標記抵達
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select c1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select mark_arrived(%L)$sql$, (select activity2_id from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  'COMPLETED 的活動不可再標記抵達，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 8. 邊界：CANCELLED 的活動不可再標記抵達
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select x1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select mark_arrived(%L)$sql$, (select activity3_id from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  'CANCELLED 的活動不可再標記抵達，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 9. 邊界：不存在的 activity_id 應被 NOT_FOUND 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select mark_arrived(%L)$sql$, gen_random_uuid()),
  'NOT_FOUND',
  '不存在的 activity_id 應被 NOT_FOUND 擋下'
);

-- -----------------------------------------------------------------------------
-- 10. 已刪除帳號呼叫 mark_arrived 應被 ACCOUNT_DELETED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select deleted_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select mark_arrived(%L)$sql$, (select activity1_id from fixtures)),
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫 mark_arrived 應被 ACCOUNT_DELETED 擋下'
);

select * from finish();

rollback;
