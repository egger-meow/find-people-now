-- =============================================================================
-- pgTAP Test — Sport-Specific Level System & Matching Engine (v1.42)
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(20);

-- -----------------------------------------------------------------------------
-- 0. Pure function unit tests on fn_sport_level_match
-- -----------------------------------------------------------------------------
select is(fn_sport_level_match('BASKETBALL_INTENSITY', 'REGULAR', 'HIGH'), true, '籃球：一般 ↔ 高強度 相鄰相容');
select is(fn_sport_level_match('BASKETBALL_INTENSITY', 'EASY', 'COMPETITIVE'), false, '籃球：輕鬆 ↔ 競技 跨級不相容');
select is(fn_sport_level_match('BASKETBALL_INTENSITY', null, 'COMPETITIVE'), true, '籃球：wildcard ↔ 競技 相容');

select is(fn_sport_level_match('BADMINTON_LEVEL', 'LEVEL_6_7', 'LEVEL_8_10'), true, '羽球：6–7 級 ↔ 8–10 級 相鄰相容');
select is(fn_sport_level_match('BADMINTON_LEVEL', 'LEVEL_1_5', 'LEVEL_11_PLUS'), false, '羽球：1–5 級 ↔ 11+ 級 跨級不相容');

select is(fn_sport_level_match('TENNIS_NTRP', 'NTRP_3_0', 'NTRP_3_5'), true, '網球：NTRP 3.0 ↔ 3.5 (<=0.5) 相容');
select is(fn_sport_level_match('TENNIS_NTRP', 'NTRP_3_0', 'NTRP_4_0'), false, '網球：NTRP 3.0 ↔ 4.0 (>0.5) 不相容');
select is(fn_sport_level_match('TENNIS_NTRP', null, 'NTRP_5_0_PLUS'), true, '網球：wildcard ↔ 5.0+ 相容');

select is(fn_sport_level_match('TABLE_TENNIS_SKILL', 'BASIC_SKILLS', 'REGULAR_PLAYER'), true, '桌球：有基本功 ↔ 固定打球 相鄰相容');
select is(fn_sport_level_match('TABLE_TENNIS_SKILL', 'CASUAL_BEGINNER', 'VARSITY_TOURNAMENT'), false, '桌球：休閒新手 ↔ 校隊/積分賽 跨級不相容');

select is(fn_sport_level_match('NONE', 'ANY', 'OTHER'), true, 'NONE 類型一律相容');

-- -----------------------------------------------------------------------------
-- 1. End-to-End matching engine test with tennis & table tennis
-- -----------------------------------------------------------------------------

create temp table test_fixtures (
  tennis_type_id uuid,
  table_tennis_type_id uuid,
  coffee_type_id uuid,
  campus_tn1 text, tn1_a_id uuid, tn1_b_id uuid,
  campus_tn2 text, tn2_a_id uuid, tn2_b_id uuid,
  campus_tt1 text, tt1_a_id uuid, tt1_b_id uuid,
  campus_cf1 text, cf1_user_id uuid, cf1_req_id uuid
);
insert into test_fixtures default values;

do $setup$
declare
  v_tennis_id uuid;
  v_table_tennis_id uuid;
  v_coffee_id uuid;
  v_now timestamptz := now();

  v_tn1_a_id uuid := gen_random_uuid();
  v_tn1_b_id uuid := gen_random_uuid();
  v_tn1_a_req match_request;
  v_tn1_b_req match_request;

  v_tn2_a_id uuid := gen_random_uuid();
  v_tn2_b_id uuid := gen_random_uuid();
  v_tn2_a_req match_request;
  v_tn2_b_req match_request;

  v_tt1_a_id uuid := gen_random_uuid();
  v_tt1_b_id uuid := gen_random_uuid();
  v_tt1_a_req match_request;
  v_tt1_b_req match_request;

  v_cf1_user_id uuid := gen_random_uuid();
begin
  select id into v_tennis_id from activity_type where name = '網球' limit 1;
  select id into v_table_tennis_id from activity_type where name = '桌球' limit 1;
  select id into v_coffee_id from activity_type where name = '吃飯/咖啡/探店' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', 'TN1區', 'TN1地點', true),
    ('NYCU', 'TN2區', 'TN2地點', true),
    ('NYCU', 'TT1區', 'TT1地點', true),
    ('NYCU', 'CF1區', 'CF1地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- 網球組 1：NTRP 3.0 vs 3.5 (相容)
  insert into auth.users (id, email) values (v_tn1_a_id, 'tn1_a@nycu.edu.tw'), (v_tn1_b_id, 'tn1_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_tn1_a_id, 'tn1_a@nycu.edu.tw', 'NYCU', 'TN1 A', 'https://avatar/1', 'UNDERGRAD', 'tn1_a_ig'),
    (v_tn1_b_id, 'tn1_b@nycu.edu.tw', 'NYCU', 'TN1 B', 'https://avatar/2', 'UNDERGRAD', 'tn1_b_ig');
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level)
  values (v_tn1_a_id, v_tennis_id, 'NYCU', 'TN1區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'NTRP_3_0')
  returning * into v_tn1_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_tn1_a_req.id, v_tn1_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level)
  values (v_tn1_b_id, v_tennis_id, 'NYCU', 'TN1區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'NTRP_3_5')
  returning * into v_tn1_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_tn1_b_req.id, v_tn1_b_id, 'OWNER', 'JOINED');

  -- 網球組 2：NTRP 3.0 vs 4.5 (不相容)
  insert into auth.users (id, email) values (v_tn2_a_id, 'tn2_a@nycu.edu.tw'), (v_tn2_b_id, 'tn2_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_tn2_a_id, 'tn2_a@nycu.edu.tw', 'NYCU', 'TN2 A', 'https://avatar/3', 'UNDERGRAD', 'tn2_a_ig'),
    (v_tn2_b_id, 'tn2_b@nycu.edu.tw', 'NYCU', 'TN2 B', 'https://avatar/4', 'UNDERGRAD', 'tn2_b_ig');
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level)
  values (v_tn2_a_id, v_tennis_id, 'NYCU', 'TN2區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'NTRP_3_0')
  returning * into v_tn2_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_tn2_a_req.id, v_tn2_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level)
  values (v_tn2_b_id, v_tennis_id, 'NYCU', 'TN2區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'NTRP_4_5')
  returning * into v_tn2_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_tn2_b_req.id, v_tn2_b_id, 'OWNER', 'JOINED');

  -- 桌球組 1：有基本功 vs 固定打球 (相容，且帶選填積分)
  insert into auth.users (id, email) values (v_tt1_a_id, 'tt1_a@nycu.edu.tw'), (v_tt1_b_id, 'tt1_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_tt1_a_id, 'tt1_a@nycu.edu.tw', 'NYCU', 'TT1 A', 'https://avatar/5', 'UNDERGRAD', 'tt1_a_ig'),
    (v_tt1_b_id, 'tt1_b@nycu.edu.tw', 'NYCU', 'TT1 B', 'https://avatar/6', 'UNDERGRAD', 'tt1_b_ig');
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level, sport_level_rating)
  values (v_tt1_a_id, v_table_tennis_id, 'NYCU', 'TT1區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'BASIC_SKILLS', 1200)
  returning * into v_tt1_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_tt1_a_req.id, v_tt1_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level, sport_level_rating)
  values (v_tt1_b_id, v_table_tennis_id, 'NYCU', 'TT1區', v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'REGULAR_PLAYER', 1450)
  returning * into v_tt1_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_tt1_b_req.id, v_tt1_b_id, 'OWNER', 'JOINED');

  -- 咖啡組：NONE 類型使用者
  insert into auth.users (id, email) values (v_cf1_user_id, 'cf1@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_cf1_user_id, 'cf1@nycu.edu.tw', 'NYCU', 'CF1 User', 'https://avatar/7', 'UNDERGRAD', 'cf1_ig');

  update test_fixtures set
    tennis_type_id = v_tennis_id, table_tennis_type_id = v_table_tennis_id, coffee_type_id = v_coffee_id,
    campus_tn1 = 'TN1區', tn1_a_id = v_tn1_a_req.id, tn1_b_id = v_tn1_b_req.id,
    campus_tn2 = 'TN2區', tn2_a_id = v_tn2_a_req.id, tn2_b_id = v_tn2_b_req.id,
    campus_tt1 = 'TT1區', tt1_a_id = v_tt1_a_req.id, tt1_b_id = v_tt1_b_req.id,
    campus_cf1 = 'CF1區', cf1_user_id = v_cf1_user_id;
end;
$setup$;

grant select, update on test_fixtures to authenticated;

set local role authenticated;

-- 驗證 create_request 在 NONE 類型下強制 null
do $$
declare
  v_req match_request;
begin
  perform set_config('request.jwt.claim.sub', (select cf1_user_id::text from test_fixtures), true);
  v_req := create_request(
    p_activity_type_id := (select coffee_type_id from test_fixtures),
    p_campus            := (select campus_cf1 from test_fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 4,
    p_allow_downgrade        := false,
    p_sport_level            := 'HIGH',
    p_sport_level_rating     := 1500
  );
  update test_fixtures set cf1_req_id = v_req.id;
end $$;

reset role;

select is(
  (select sport_level from match_request where id = (select cf1_req_id from test_fixtures)),
  null,
  'NONE 類型建立 request 時帶入 sport_level 應被強制設為 null'
);

-- 執行 matching engine
select is(fn_run_matching_engine(), 2, 'Matching engine 應撮合成功 2 組（網球 3.0/3.5、桌球 基本功/固定打球）');

select is(
  (select count(*)::int from match_request
    where id in ((select tn1_a_id from test_fixtures), (select tn1_b_id from test_fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '網球 NTRP 3.0 與 3.5 應撮合成功進入 PENDING_CONFIRMATION'
);

select is(
  (select count(*)::int from match_request
    where id in ((select tn2_a_id from test_fixtures), (select tn2_b_id from test_fixtures))
      and status = 'REQUESTING'),
  2,
  '網球 NTRP 3.0 與 4.5 不應撮合，維持 REQUESTING'
);

select is(
  (select count(*)::int from match_request
    where id in ((select tt1_a_id from test_fixtures), (select tt1_b_id from test_fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '桌球 基本功 與 固定打球 應撮合成功進入 PENDING_CONFIRMATION'
);

-- -----------------------------------------------------------------------------
-- 2. Seeds & Alias Search Tests
-- -----------------------------------------------------------------------------
select is(
  (select count(*)::int from activity_type where name = '網球' and status = 'APPROVED' and level_system = 'TENNIS_NTRP' and sort_order = 10),
  1,
  '官方 Seed：網球存在恰好 1 筆且 level_system = TENNIS_NTRP, sort_order = 10'
);

select is(
  (select count(*)::int from activity_type where name = '桌球' and status = 'APPROVED' and level_system = 'TABLE_TENNIS_SKILL' and sort_order = 10),
  1,
  '官方 Seed：桌球存在恰好 1 筆且 level_system = TABLE_TENNIS_SKILL, sort_order = 10'
);

select is(
  (select name from search_activity_type('乒乓球') limit 1),
  '桌球',
  '別名搜尋：搜尋「乒乓球」應命中官方活動「桌球」'
);

select is(
  (select name from search_activity_type('Ping Pong') limit 1),
  '桌球',
  '別名搜尋：搜尋「Ping Pong」應命中官方活動「桌球」'
);

select * from finish();

rollback;
