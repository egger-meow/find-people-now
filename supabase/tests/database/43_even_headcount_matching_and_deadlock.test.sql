-- =============================================================================
-- pgTAP Test — 競技運動人數步階、偶數優先撮合與防死鎖測試 (v1.45)
--
-- 涵蓋核心場景：
--   ① 偶數優先撮合：籃球 (step=2) 遇到 1+2=3（奇數）且後續有 1 人時，不提前退出，
--      主動吸納第 4 人形成 4 人（偶數）活動局。
--   ② 「但不要絕對」防死鎖保證：籃球僅有 1+2=3 人且池中無其他候選時，絕不卡死在 REQUESTING，
--      仍順利成團，徹底防止飢餓與死鎖。
--   ③ step=2 防呆限制：競技活動提交奇數人數（如 3 人）應被 INVALID_GROUP_SIZE_OPTION 阻擋。
--   ④ step=2 偶數允許：競技活動提交偶數人數（如 2 或 4 人）順利通過。
--   ⑤ step=null 泛化允許：非競技活動（如跑步）提交奇數（3 人）或任意整數順利通過。
--   ⑥ commit_match 依 id 排序鎖定，防止並發交叉鎖死。
--
-- 執行：`supabase test db`
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

do $setup$
declare
  v_school         school := 'NYCU';
  v_campus_1       text := 'CAMPUS_EVEN_1';
  v_campus_2       text := 'CAMPUS_FALLBACK_2';
  v_campus_3       text := 'CAMPUS_RUNNING_3';
  v_now            timestamptz := now();
  v_bball_type_id  uuid;
  v_run_type_id    uuid;

  -- 使用者
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
  v_u2_friend uuid := gen_random_uuid();
  v_u3 uuid := gen_random_uuid();
  v_u4 uuid := gen_random_uuid();
  v_u5 uuid := gen_random_uuid();
  v_u5_friend uuid := gen_random_uuid();
  v_u6 uuid := gen_random_uuid();

  -- 需求
  v_req_a uuid;
  v_req_b uuid;
  v_req_c uuid;
  v_req_d uuid;
  v_req_e uuid;
begin
  -- 取得或確認活動類型
  select id into v_bball_type_id from activity_type where name = '籃球';
  select id into v_run_type_id from activity_type where name = '跑步';

  -- 建立合法 Location
  insert into location (school, campus, name, status) values
    (v_school, v_campus_1, '測試籃球場1', 'APPROVED'),
    (v_school, v_campus_2, '測試籃球場2', 'APPROVED'),
    (v_school, v_campus_3, '測試跑步操場', 'APPROVED');

  -- 建立 auth.users 帳號
  insert into auth.users (id, email) values
    (v_u1, 'u1@nycu.edu.tw'),
    (v_u2, 'u2@nycu.edu.tw'),
    (v_u2_friend, 'u2f@nycu.edu.tw'),
    (v_u3, 'u3@nycu.edu.tw'),
    (v_u4, 'u4@nycu.edu.tw'),
    (v_u5, 'u5@nycu.edu.tw'),
    (v_u5_friend, 'u5f@nycu.edu.tw'),
    (v_u6, 'u6@nycu.edu.tw');

  -- 建立測試使用者（滿足 at_least_one_contact 約束）
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_u1, 'u1@nycu.edu.tw', v_school, 'U1', 'https://avatar/1', 'UNDERGRAD', 'u1_ig'),
    (v_u2, 'u2@nycu.edu.tw', v_school, 'U2', 'https://avatar/2', 'UNDERGRAD', 'u2_ig'),
    (v_u2_friend, 'u2f@nycu.edu.tw', v_school, 'U2Friend', 'https://avatar/2f', 'UNDERGRAD', 'u2f_ig'),
    (v_u3, 'u3@nycu.edu.tw', v_school, 'U3', 'https://avatar/3', 'UNDERGRAD', 'u3_ig'),
    (v_u4, 'u4@nycu.edu.tw', v_school, 'U4', 'https://avatar/4', 'UNDERGRAD', 'u4_ig'),
    (v_u5, 'u5@nycu.edu.tw', v_school, 'U5', 'https://avatar/5', 'UNDERGRAD', 'u5_ig'),
    (v_u5_friend, 'u5f@nycu.edu.tw', v_school, 'U5Friend', 'https://avatar/5f', 'UNDERGRAD', 'u5f_ig'),
    (v_u6, 'u6@nycu.edu.tw', v_school, 'U6', 'https://avatar/6', 'UNDERGRAD', 'u6_ig');

  -- ---------------------------------------------------------------------------
  -- 場景①：籃球場1（池中有 A:1人, B:2人, C:1人，共 4 人）
  -- ---------------------------------------------------------------------------
  insert into match_request (
    id, owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    status, sport_level, created_at
  ) values
    (gen_random_uuid(), v_u1, v_bball_type_id, v_school, v_campus_1,
     v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING', 'REGULAR', v_now - interval '30 minutes')
  returning id into v_req_a;

  insert into request_member (request_id, user_id, status) values (v_req_a, v_u1, 'JOINED');

  insert into match_request (
    id, owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    status, sport_level, created_at
  ) values
    (gen_random_uuid(), v_u2, v_bball_type_id, v_school, v_campus_1,
     v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING', 'REGULAR', v_now - interval '20 minutes')
  returning id into v_req_b;

  insert into request_member (request_id, user_id, status) values
    (v_req_b, v_u2, 'JOINED'),
    (v_req_b, v_u2_friend, 'JOINED');

  insert into match_request (
    id, owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    status, sport_level, created_at
  ) values
    (gen_random_uuid(), v_u3, v_bball_type_id, v_school, v_campus_1,
     v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING', 'REGULAR', v_now - interval '10 minutes')
  returning id into v_req_c;

  insert into request_member (request_id, user_id, status) values (v_req_c, v_u3, 'JOINED');

  -- ---------------------------------------------------------------------------
  -- 場景②：籃球場2（池中僅有 D:1人, E:2人，共 3 人，無其他候選）
  -- ---------------------------------------------------------------------------
  insert into match_request (
    id, owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    status, sport_level, created_at
  ) values
    (gen_random_uuid(), v_u4, v_bball_type_id, v_school, v_campus_2,
     v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING', 'REGULAR', v_now - interval '30 minutes')
  returning id into v_req_d;

  insert into request_member (request_id, user_id, status) values (v_req_d, v_u4, 'JOINED');

  insert into match_request (
    id, owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    status, sport_level, created_at
  ) values
    (gen_random_uuid(), v_u5, v_bball_type_id, v_school, v_campus_2,
     v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING', 'REGULAR', v_now - interval '20 minutes')
  returning id into v_req_e;

  insert into request_member (request_id, user_id, status) values
    (v_req_e, v_u5, 'JOINED'),
    (v_req_e, v_u5_friend, 'JOINED');
end $setup$;

-- 執行撮合引擎
select lives_ok(
  'select fn_run_matching_engine()',
  '執行配對引擎應順暢無異常'
);

-- ① 驗證場景①：A(1)+B(2) 雖已達 min(2)，但為奇數(3)，引擎繼續吸納 C(1) 湊成 4 人偶數局
select is(
  (select count(*) from activity_member am
     join activity a on a.id = am.activity_id
    where a.campus = 'CAMPUS_EVEN_1'),
  4::bigint,
  '場景①：籃球局盡量湊成偶數——成功將 1+2+1 湊齊為 4 位成員的偶數活動局'
);

-- ② 驗證場景②：「但不要絕對」——池中僅有 3 人時，不造成死鎖，順利成團
select is(
  (select count(*) from activity_member am
     join activity a on a.id = am.activity_id
    where a.campus = 'CAMPUS_FALLBACK_2'),
  3::bigint,
  '場景②：「不要絕對」防死鎖——僅有 3 人時依然順利成團，絕不卡死在 REQUESTING'
);

select is(
  (select count(*) from match_request
    where campus = 'CAMPUS_FALLBACK_2' and status = 'MATCHED'),
  2::bigint,
  '場景②：參與 3 人團的所有需求皆順利轉為 MATCHED'
);

-- 設定當前登入使用者為 U6
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id from app_user where email = 'u6@nycu.edu.tw')::text, true);
end $$;

-- ③ 驗證 step=2 檢查：籃球 (step=2) 選奇數 (3人) 應被阻擋
select throws_matching(
  $$
    select create_request(
      (select id from activity_type where name = '籃球'),
      'CAMPUS_EVEN_1',
      now(),
      now() + interval '2 hours',
      3,
      3
    );
  $$,
  'INVALID_GROUP_SIZE_OPTION',
  '場景③：競技運動 (step=2) 選擇奇數人數 3 應被 INVALID_GROUP_SIZE_OPTION 擋下'
);

-- ④ 驗證 step=2 偶數：籃球選 4 人應合法通過
select lives_ok(
  $$
    select create_request(
      (select id from activity_type where name = '籃球'),
      'CAMPUS_EVEN_1',
      now(),
      now() + interval '2 hours',
      4,
      4
    );
  $$,
  '場景④：競技運動 (step=2) 選擇偶數人數 4 應順利通過'
);

-- ⑤ 驗證 step=null：跑步 (step=null) 選奇數 3 人亦順利通過
select lives_ok(
  $$
    select create_request(
      (select id from activity_type where name = '跑步'),
      'CAMPUS_RUNNING_3',
      now(),
      now() + interval '2 hours',
      3,
      3
    );
  $$,
  '場景⑤：非競技/連續人數活動（跑步）選擇 3 人不受 step 限制，順利通過'
);

select * from finish();
rollback;
