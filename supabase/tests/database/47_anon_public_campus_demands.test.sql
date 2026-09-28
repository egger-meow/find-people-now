-- =============================================================================
-- pgTAP Test: 47_anon_public_campus_demands.test.sql
--
-- 驗證未登入訪客「先看活動，再登入加入」之粗粒度、唯讀探索介面與隱私防禦
-- 1. anon 角色可正常執行 get_public_campus_demands
-- 2. anon 角色絕無法呼叫受保護的 get_campus_demands（42501 permission denied）
-- 3. anon 角色受 RLS 阻隔，無法讀取 match_request 與 request_member
-- 4. 小樣本抑制（k-anonymity）：單人需求 (person_count = 1) 不公開展示，標記 has_suppressed_demands
-- 5. 多人相容 (person_count >= 2)：正常公開展示，並區分等待中人數與今日已成團人數
-- 6. 時間粗化：回傳時間窗以 30 分鐘為基準單位（秒與非 00/30 分鐘被消除）
-- 7. 屬性去識別化：回傳 JSON 絕不包含個人識別碼、評分數值或自由填寫科目
-- 8. 排除過期需求：過去時間需求不展示
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(15);

-- -----------------------------------------------------------------------------
-- Setup
-- -----------------------------------------------------------------------------
create temp table test_fixtures (
  badminton_id   uuid,
  coffee_id      uuid,
  tennis_id      uuid,
  campus         text,
  other_campus   text,
  user1          uuid,
  user2          uuid,
  user3          uuid,
  user4          uuid
);
insert into test_fixtures default values;

do $setup$
declare
  v_badminton_id uuid;
  v_coffee_id    uuid;
  v_tennis_id    uuid;
  v_campus       text := '光復';
  v_other_campus text := '博愛';
  v_u1           uuid := gen_random_uuid();
  v_u2           uuid := gen_random_uuid();
  v_u3           uuid := gen_random_uuid();
  v_u4           uuid := gen_random_uuid();
  v_now          timestamptz := now();
  v_time_start   timestamptz := date_trunc('hour', v_now) + interval '2 hours 17 minutes 45 seconds';
  v_time_end     timestamptz := date_trunc('hour', v_now) + interval '4 hours 12 minutes 10 seconds';
  v_past_start   timestamptz := v_now - interval '3 hours';
  v_past_end     timestamptz := v_now - interval '1 hour';
  v_act_id       uuid;
  v_loc_id       uuid;
begin
  select id into v_badminton_id from activity_type where name = '羽球' limit 1;
  select id into v_coffee_id from activity_type where name in ('吃飯/咖啡/探店', '咖啡/聊天') limit 1;
  select id into v_tennis_id from activity_type where name = '網球' limit 1;

  insert into auth.users (id, email) values
    (v_u1, 'test_anon1@nycu.edu.tw'),
    (v_u2, 'test_anon2@nycu.edu.tw'),
    (v_u3, 'test_anon3@nycu.edu.tw'),
    (v_u4, 'test_anon4@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_u1, 'test_anon1@nycu.edu.tw', 'NYCU', 'User1', 'https://avatar1', 'UNDERGRAD', 'ig1'),
    (v_u2, 'test_anon2@nycu.edu.tw', 'NYCU', 'User2', 'https://avatar2', 'UNDERGRAD', 'ig2'),
    (v_u3, 'test_anon3@nycu.edu.tw', 'NYCU', 'User3', 'https://avatar3', 'UNDERGRAD', 'ig3'),
    (v_u4, 'test_anon4@nycu.edu.tw', 'NYCU', 'User4', 'https://avatar4', 'UNDERGRAD', 'ig4');

  update test_fixtures set
    badminton_id = v_badminton_id,
    coffee_id = v_coffee_id,
    tennis_id = v_tennis_id,
    campus = v_campus,
    other_campus = v_other_campus,
    user1 = v_u1,
    user2 = v_u2,
    user3 = v_u3,
    user4 = v_u4;

  -- 1. 羽球：2 個使用者發起相同時段（person_count = 2，符合 k >= 2，應公開展示）
  insert into match_request (id, owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, sport_level, status)
  values
    ('11111111-1111-1111-1111-111111111111', v_u1, v_badminton_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'EASY', 'REQUESTING'),
    ('22222222-2222-2222-2222-222222222222', v_u2, v_badminton_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'EASY', 'REQUESTING');

  insert into request_member (request_id, user_id, role, status) values
    ('11111111-1111-1111-1111-111111111111', v_u1, 'OWNER', 'JOINED'),
    ('22222222-2222-2222-2222-222222222222', v_u2, 'OWNER', 'JOINED');

  -- 2. 咖啡：只有 1 個使用者發起（person_count = 1，小樣本，應被抑制隱藏）
  insert into match_request (id, owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    ('33333333-3333-3333-3333-333333333333', v_u3, v_coffee_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'REQUESTING');

  insert into request_member (request_id, user_id, role, status) values
    ('33333333-3333-3333-3333-333333333333', v_u3, 'OWNER', 'JOINED');

  -- 3. 網球：已過期需求（latest_start < now()，不論人數皆不應展示）
  insert into match_request (id, owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    ('44444444-4444-4444-4444-444444444444', v_u4, v_tennis_id, 'NYCU', v_campus, v_past_start, v_past_end, 2, 4, 'REQUESTING');

  insert into request_member (request_id, user_id, role, status) values
    ('44444444-4444-4444-4444-444444444444', v_u4, 'OWNER', 'JOINED');

  -- 4. 建立一筆今日已成團羽球活動（status = MATCHED），驗證 formed_group_count 與 formed_person_count
  insert into activity (id, activity_type_id, school, campus, start_time, estimated_end_time, status)
  values ('55555555-5555-5555-5555-555555555555', v_badminton_id, 'NYCU', v_campus, v_time_start, v_time_end, 'MATCHED')
  returning id into v_act_id;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  values
    (v_act_id, v_u1, '11111111-1111-1111-1111-111111111111', 'JOINED'),
    (v_act_id, v_u2, '22222222-2222-2222-2222-222222222222', 'JOINED');

end $setup$;

-- -----------------------------------------------------------------------------
-- 測試開始：模擬 anon 訪客角色
-- -----------------------------------------------------------------------------
set local role anon;

-- 1. 匿名者呼叫 get_public_campus_demands 應成功返回 JSON
select ok(
  get_public_campus_demands('NYCU'::school, '光復') is not null,
  'anon 訪客可成功執行 get_public_campus_demands'
);

-- 2. 匿名者無權呼叫 authenticated 限定的 get_campus_demands（Postgres 權限層拋出 42501）
select throws_ok(
  $call$ select * from get_campus_demands('NYCU'::school, '光復') $call$,
  '42501',
  'permission denied for function get_campus_demands',
  'anon 訪客無法呼叫受保護的 get_campus_demands'
);

-- 3. 匿名者受 RLS 阻隔，無法讀取 match_request 資料表
select is(
  (select count(*)::int from match_request),
  0,
  'anon 訪客讀取 match_request 只能得到 0 筆（RLS 隔離）'
);

-- 4. 匿名者受 RLS 阻隔，無法讀取 request_member 資料表
select is(
  (select count(*)::int from request_member),
  0,
  'anon 訪客讀取 request_member 只能得到 0 筆（RLS 隔離）'
);

-- 5. 驗證校區清單：包含光復等核准校區
select ok(
  (get_public_campus_demands('NYCU'::school, '光復')->'campuses')::text like '%"光復"%',
  '回傳包含該校已核准校區清單'
);

-- 6. 小樣本抑制：羽球 (person_count = 2) 公開展示，咖啡 (person_count = 1) 遭抑制
select is(
  jsonb_array_length(get_public_campus_demands('NYCU'::school, '光復')->'demands'),
  1,
  '只公開展示符合小樣本門檻 (k>=2) 的需求卡（共 1 張，為羽球）'
);

-- 7. 驗證咖啡單人需求確實觸發 has_suppressed_demands = true
select is(
  (get_public_campus_demands('NYCU'::school, '光復')->>'has_suppressed_demands')::boolean,
  true,
  '單人需求被小樣本抑制時，has_suppressed_demands 標記應為 true'
);

-- 8. 驗證羽球需求卡內容：等待人數 2、需求組數 2
select is(
  (get_public_campus_demands('NYCU'::school, '光復')->'demands'->0->>'waiting_person_count')::int,
  2,
  '羽球卡片等待人數為 2'
);
select is(
  (get_public_campus_demands('NYCU'::school, '光復')->'demands'->0->>'waiting_request_count')::int,
  2,
  '羽球卡片等待組數為 2'
);

-- 9. 驗證今日已成團人數與組數區分
select is(
  (get_public_campus_demands('NYCU'::school, '光復')->'demands'->0->>'formed_person_count')::int,
  2,
  '羽球卡片今日已成團人數為 2'
);
select is(
  (get_public_campus_demands('NYCU'::school, '光復')->'demands'->0->>'formed_group_count')::int,
  1,
  '羽球卡片今日已成團組數為 1'
);

-- 10. 驗證時間粗化：分鐘與秒數皆被粗化為 30 分鐘間隔（非 17 分鐘 45 秒）
select ok(
  (get_public_campus_demands('NYCU'::school, '光復')->'demands'->0->>'earliest_start') ~ ':[03]0:00',
  '時間窗已按 30 分鐘粗化（秒與非00/30分已被消除）'
);

-- 11. 驗證個資去識別性：回傳 JSON 絕不包含 owner_id, user_id, request_id, email, display_name
select ok(
  not ((get_public_campus_demands('NYCU'::school, '光復')->'demands'->0)::text ~* '(owner_id|user_id|request_id|email|display_name|avatar_url|sport_level_rating|study_target)'),
  '公開回應絕不包含個人識別碼、評分數值或自介科目'
);

-- 12. 驗證過期需求（網球）絕不展示
select ok(
  not ((get_public_campus_demands('NYCU'::school, '光復')->'demands')::text like '%網球%'),
  '過期需求絕不出現在公開探索中'
);

-- 13. 校區切換：博愛校區無任何需求，has_suppressed_demands 為 false
select is(
  (get_public_campus_demands('NYCU'::school, '博愛')->>'has_suppressed_demands')::boolean,
  false,
  '完全無需求之校區，has_suppressed_demands 為 false（真實空狀態）'
);

select * from finish();

rollback;
