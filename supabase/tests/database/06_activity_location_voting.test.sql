-- =============================================================================
-- pgTAP Test — Activity Location 投票機制 (docs/API.md §6.4/6.5, SPEC §9.1, v1.11)
-- 涵蓋：NOT_ACTIVITY_MEMBER、INVALID_CAMPUS_SCOPE、提案=自動投票、改票、
-- fn_start_activities 依得票鎖定 (含同票取最早提案者)、鎖定後 ACTIVITY_LOCATION_LOCKED、
-- vote_activity_location 對不存在的候選回 NOT_FOUND、零候選 fallback
-- （activity_location_id 維持 NULL，不代替使用者決定）+
-- fn_remind_missing_location_candidates 的通知與去重。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(15);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  m1_id        uuid,  -- activity_1 member
  m2_id        uuid,  -- activity_1 member
  m3_id        uuid,  -- activity_1 member
  outsider_id  uuid,  -- 完全不是任何活動的成員
  t2_m1_id     uuid,  -- activity_2 member (tie-break)
  t2_m2_id     uuid,  -- activity_2 member (tie-break)
  t3_m1_id     uuid,  -- activity_3 member (零候選)
  t3_m2_id     uuid,  -- activity_3 member (零候選)
  act_type_id  uuid,
  campus       text,
  loc_p_id     uuid,  -- 範圍內候選 P
  loc_q_id     uuid,  -- 範圍內候選 Q
  loc_out_id   uuid,  -- 範圍外地點（不同 campus）
  activity1_id uuid,
  activity2_id uuid,
  activity3_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_m1        uuid := gen_random_uuid();
  v_m2        uuid := gen_random_uuid();
  v_m3        uuid := gen_random_uuid();
  v_outsider  uuid := gen_random_uuid();
  v_t2_m1     uuid := gen_random_uuid();
  v_t2_m2     uuid := gen_random_uuid();
  v_t3_m1     uuid := gen_random_uuid();
  v_t3_m2     uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_loc_p       uuid;
  v_loc_q       uuid;
  v_loc_out     uuid;
  v_req1        uuid;
  v_req2        uuid;
  v_req3        uuid;
  v_activity1   activity;
  v_activity2   activity;
  v_activity3   activity;
begin
  insert into auth.users (id, email) values
    (v_m1, 'alv_m1@nycu.edu.tw'), (v_m2, 'alv_m2@nycu.edu.tw'), (v_m3, 'alv_m3@nycu.edu.tw'),
    (v_outsider, 'alv_outsider@nycu.edu.tw'),
    (v_t2_m1, 'alv_t2_m1@nycu.edu.tw'), (v_t2_m2, 'alv_t2_m2@nycu.edu.tw'),
    (v_t3_m1, 'alv_t3_m1@nycu.edu.tw'), (v_t3_m2, 'alv_t3_m2@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_m1, 'alv_m1@nycu.edu.tw', 'NYCU', 'Alv M1', 'https://avatar.alv_m1', 'MASTER', 'alv_m1_line'),
    (v_m2, 'alv_m2@nycu.edu.tw', 'NYCU', 'Alv M2', 'https://avatar.alv_m2', 'MASTER', 'alv_m2_line'),
    (v_m3, 'alv_m3@nycu.edu.tw', 'NYCU', 'Alv M3', 'https://avatar.alv_m3', 'MASTER', 'alv_m3_line'),
    (v_outsider, 'alv_outsider@nycu.edu.tw', 'NYCU', 'Alv Outsider', 'https://avatar.alv_outsider', 'MASTER', 'alv_outsider_line'),
    (v_t2_m1, 'alv_t2_m1@nycu.edu.tw', 'NYCU', 'Alv T2M1', 'https://avatar.alv_t2_m1', 'MASTER', 'alv_t2_m1_line'),
    (v_t2_m2, 'alv_t2_m2@nycu.edu.tw', 'NYCU', 'Alv T2M2', 'https://avatar.alv_t2_m2', 'MASTER', 'alv_t2_m2_line'),
    (v_t3_m1, 'alv_t3_m1@nycu.edu.tw', 'NYCU', 'Alv T3M1', 'https://avatar.alv_t3_m1', 'MASTER', 'alv_t3_m1_line'),
    (v_t3_m2, 'alv_t3_m2@nycu.edu.tw', 'NYCU', 'Alv T3M2', 'https://avatar.alv_t3_m2', 'MASTER', 'alv_t3_m2_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  -- 候選範圍內兩筆地點（同 school/campus）+ 一筆範圍外地點（不同 campus）
  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus, 'P 候選地點', true),
    ('NYCU', v_campus, 'Q 候選地點', true),
    ('NYCU', '博愛', '範圍外地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  select id into v_loc_p   from location where school = 'NYCU' and name = 'P 候選地點';
  select id into v_loc_q   from location where school = 'NYCU' and name = 'Q 候選地點';
  select id into v_loc_out from location where school = 'NYCU' and name = '範圍外地點';

  -- activity_member.source_request_id 是 NOT NULL FK → match_request，每個 activity
  -- 各建一筆已 MATCHED 的 match_request 當來源（測試不關心撮合細節，只需要滿足 FK）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_t2_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req2;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_t3_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req3;

  -- activity_1：3 位成員，用來測 NOT_ACTIVITY_MEMBER / INVALID_CAMPUS_SCOPE /
  -- 提案=自動投票 / 改票 / 依得票鎖定 / 鎖定後 ACTIVITY_LOCATION_LOCKED
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity1;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity1.id, u, v_req1, 'JOINED' from unnest(array[v_m1, v_m2, v_m3]) as u;

  -- activity_2：2 位成員各自提一個不同候選 → 1:1 平票，測同票取最早提案者
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity2;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity2.id, u, v_req2, 'JOINED' from unnest(array[v_t2_m1, v_t2_m2]) as u;

  -- activity_3：2 位成員，完全不提案 → 零候選 fallback + 提醒通知
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '10 minutes', now() + interval '1 hour', 'MATCHED')
  returning * into v_activity3;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity3.id, u, v_req3, 'JOINED' from unnest(array[v_t3_m1, v_t3_m2]) as u;

  update fixtures set
    m1_id = v_m1, m2_id = v_m2, m3_id = v_m3, outsider_id = v_outsider,
    t2_m1_id = v_t2_m1, t2_m2_id = v_t2_m2, t3_m1_id = v_t3_m1, t3_m2_id = v_t3_m2,
    act_type_id = v_act_type_id, campus = v_campus,
    loc_p_id = v_loc_p, loc_q_id = v_loc_q, loc_out_id = v_loc_out,
    activity1_id = v_activity1.id, activity2_id = v_activity2.id, activity3_id = v_activity3.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 非活動成員呼叫 propose_activity_location 應被 NOT_ACTIVITY_MEMBER 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select propose_activity_location(%L, %L)$sql$,
    (select activity1_id from fixtures), (select loc_p_id from fixtures)),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員提案應被 NOT_ACTIVITY_MEMBER 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. 成員提案範圍外地點（不同 campus）應被 INVALID_CAMPUS_SCOPE 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select propose_activity_location(%L, %L)$sql$,
    (select activity1_id from fixtures), (select loc_out_id from fixtures)),
  'INVALID_CAMPUS_SCOPE',
  '提案範圍外（不同 campus）地點應被 INVALID_CAMPUS_SCOPE 擋下'
);

-- -----------------------------------------------------------------------------
-- 3. m1 提案候選 P：應同時建立 activity_location_option 與自動投給自己的
--    activity_location_vote
-- -----------------------------------------------------------------------------

do $$ begin
  perform propose_activity_location(
    (select activity1_id from fixtures), (select loc_p_id from fixtures)
  );
end $$;

select ok(
  exists (
    select 1 from activity_location_option
     where activity_id = (select activity1_id from fixtures)
       and location_id = (select loc_p_id from fixtures)
       and proposed_by = (select m1_id from fixtures)
  ) and exists (
    select 1 from activity_location_vote
     where activity_id = (select activity1_id from fixtures)
       and user_id = (select m1_id from fixtures)
       and location_id = (select loc_p_id from fixtures)
  ),
  'm1 提案候選 P 應同時建立候選記錄與自動投給自己的投票記錄'
);

-- -----------------------------------------------------------------------------
-- 4. m2 提案候選 Q（第二個候選，稍晚建立）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m2_id::text from fixtures), true);
  perform propose_activity_location(
    (select activity1_id from fixtures), (select loc_q_id from fixtures)
  );
end $$;

select ok(
  exists (
    select 1 from activity_location_option
     where activity_id = (select activity1_id from fixtures)
       and location_id = (select loc_q_id from fixtures)
  ),
  'm2 提案候選 Q 應成功建立'
);

-- -----------------------------------------------------------------------------
-- 5. m3 對候選 P 投票（vote_activity_location，非提案動作）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m3_id::text from fixtures), true);
  perform vote_activity_location(
    (select activity1_id from fixtures), (select loc_p_id from fixtures)
  );
end $$;

select is(
  (select location_id from activity_location_vote
    where activity_id = (select activity1_id from fixtures) and user_id = (select m3_id from fixtures)),
  (select loc_p_id from fixtures),
  'm3 投給候選 P 應正確記錄'
);

-- -----------------------------------------------------------------------------
-- 6. vote_activity_location 對不存在的候選（未被提案過的地點）應回 NOT_FOUND
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select vote_activity_location(%L, %L)$sql$,
    (select activity1_id from fixtures), (select loc_out_id from fixtures)),
  'NOT_FOUND',
  '對尚未被提案過的地點投票應被 NOT_FOUND 擋下'
);

-- -----------------------------------------------------------------------------
-- 7. 此時候選 P 得 2 票（m1, m3）、候選 Q 得 1 票（m2）——fn_start_activities
--    到點時應鎖定候選 P（得票最高）。先把 activity_1 的 start_time 撥回過去。
-- -----------------------------------------------------------------------------

do $$ begin
  update activity set start_time = now() - interval '1 minute'
   where id = (select activity1_id from fixtures);
  perform fn_start_activities();
end $$;

select is(
  (select activity_location_id from activity where id = (select activity1_id from fixtures)),
  (select loc_p_id from fixtures),
  'fn_start_activities 應依得票數鎖定候選 P（2 票 > 1 票）'
);

select is(
  (select status::text from activity where id = (select activity1_id from fixtures)),
  'ONGOING',
  'activity_1 鎖定地點後應轉為 ONGOING'
);

-- -----------------------------------------------------------------------------
-- 8. 鎖定後再提案應被 ACTIVITY_LOCATION_LOCKED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select propose_activity_location(%L, %L)$sql$,
    (select activity1_id from fixtures), (select loc_q_id from fixtures)),
  'ACTIVITY_LOCATION_LOCKED',
  '已鎖定 Activity Location 後再提案應被 ACTIVITY_LOCATION_LOCKED 擋下'
);

-- -----------------------------------------------------------------------------
-- 9. activity_2：t2_m1 提案 P、t2_m2 提案 Q，1:1 平票 → fn_start_activities
--    應取最早提案者（t2_m1 的 P，因為先建立）勝出
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select t2_m1_id::text from fixtures), true);
  perform propose_activity_location(
    (select activity2_id from fixtures), (select loc_p_id from fixtures)
  );
  perform set_config('request.jwt.claim.sub', (select t2_m2_id::text from fixtures), true);
  perform propose_activity_location(
    (select activity2_id from fixtures), (select loc_q_id from fixtures)
  );
  update activity set start_time = now() - interval '1 minute'
   where id = (select activity2_id from fixtures);
  perform fn_start_activities();
end $$;

select is(
  (select activity_location_id from activity where id = (select activity2_id from fixtures)),
  (select loc_p_id from fixtures),
  '同票時 fn_start_activities 應取最早提案的候選 P（t2_m1 先提案）勝出'
);

-- -----------------------------------------------------------------------------
-- 10. activity_3：零候選 → fn_remind_missing_location_candidates 應通知全體成員
-- -----------------------------------------------------------------------------

select is(
  fn_remind_missing_location_candidates()::int,
  1,
  '零候選且進入提醒視窗的活動應被 fn_remind_missing_location_candidates 處理 1 筆'
);

select is(
  (select count(*)::int from notification
    where event_type = 'LOCATION_NOT_YET_PROPOSED'
      and (payload->>'activity_id')::uuid = (select activity3_id from fixtures)),
  2,
  'activity_3 的 2 位成員都應收到 LOCATION_NOT_YET_PROPOSED 通知'
);

-- -----------------------------------------------------------------------------
-- 11. 去重：再次呼叫不應重複發送
-- -----------------------------------------------------------------------------

select is(
  fn_remind_missing_location_candidates()::int,
  0,
  '已發過提醒的活動不應被重複處理（去重靠既有 notification 資料查詢）'
);

-- -----------------------------------------------------------------------------
-- 12. activity_3 到點仍零候選：fn_start_activities 不代替使用者決定，
--     activity_location_id 維持 NULL，仍照常轉 ONGOING
-- -----------------------------------------------------------------------------

do $$ begin
  update activity set start_time = now() - interval '1 minute'
   where id = (select activity3_id from fixtures);
  perform fn_start_activities();
end $$;

select is(
  (select activity_location_id from activity where id = (select activity3_id from fixtures)),
  null,
  '零候選時 fn_start_activities 不代替使用者決定，activity_location_id 應維持 NULL'
);

select is(
  (select status::text from activity where id = (select activity3_id from fixtures)),
  'ONGOING',
  '即使零候選，activity_3 仍應照常轉為 ONGOING（不卡狀態機）'
);

select * from finish();

rollback;
