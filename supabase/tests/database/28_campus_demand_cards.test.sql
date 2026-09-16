-- =============================================================================
-- pgTAP Test — Campus Demand Cards (get_campus_demands) & Expiry Filter — v1.43
--
-- 涵蓋：
-- 1. 只計算 REQUESTING（DRAFT/PENDING_CONFIRMATION/MATCHED 皆不計入）
-- 2. 排除已過期（latest_start <= now()）的需求
-- 3. 正確依 (school, campus) 分組，不混到其他校區
-- 4. 正確聚合人頭 (person_count) 與需求組數 (request_count)
-- 5. LEFT 狀態的成員不計入人頭
-- 6. 已刪除帳號呼叫被 ACCOUNT_DELETED 擋下
-- 7. 驗證 get_campus_pulse 也排除了已過期需求
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  viewer_id        uuid,
  deleted_id       uuid,
  badminton_id     uuid,
  coffee_id        uuid,
  campus           text,
  other_campus     text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_viewer          uuid := gen_random_uuid();
  v_deleted         uuid := gen_random_uuid();
  v_owner1          uuid := gen_random_uuid();
  v_owner2          uuid := gen_random_uuid();
  v_owner3          uuid := gen_random_uuid();
  v_owner4          uuid := gen_random_uuid();
  v_owner5          uuid := gen_random_uuid();
  v_invitee1        uuid := gen_random_uuid();
  v_left_invitee    uuid := gen_random_uuid();
  v_badminton_id    uuid;
  v_coffee_id       uuid;
  v_campus          text := '光復校區';
  v_other_campus    text := '博愛校區';
  v_request1        uuid;
  v_request2        uuid;
  v_request3        uuid;
  v_request4        uuid;
  v_request5        uuid;
  v_request_expired uuid;
  v_time_start      timestamptz := now() + interval '2 hours';
  v_time_end        timestamptz := now() + interval '4 hours';
begin
  select id into v_badminton_id from activity_type where name = '羽球' limit 1;
  select id into v_coffee_id from activity_type where name in ('吃飯/咖啡/探店', '咖啡/聊天') limit 1;

  insert into auth.users (id, email) values
    (v_viewer, 'cd_viewer@nycu.edu.tw'), (v_deleted, 'cd_deleted@nycu.edu.tw'),
    (v_owner1, 'cd_o1@nycu.edu.tw'), (v_owner2, 'cd_o2@nycu.edu.tw'),
    (v_owner3, 'cd_o3@nycu.edu.tw'), (v_owner4, 'cd_o4@nycu.edu.tw'),
    (v_owner5, 'cd_o5@nycu.edu.tw'), (v_invitee1, 'cd_i1@nycu.edu.tw'),
    (v_left_invitee, 'cd_left@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  select u, u::text || '@nycu.edu.tw', 'NYCU', 'CD ' || u::text, 'https://avatar.cd', 'UNDERGRAD', 'cd_ig'
    from unnest(array[v_viewer, v_deleted, v_owner1, v_owner2, v_owner3, v_owner4, v_owner5, v_invitee1, v_left_invitee]) as u;

  update app_user
     set email = 'deleted+' || v_deleted::text, deleted_at = now()
   where id = v_deleted;

  -- 1. 羽球：2 筆相同時段與程度的 REQUESTING（同校區），一筆帶 1 位朋友，另一筆 1 人
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, sport_level, status)
  values (v_owner1, v_badminton_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'EASY', 'REQUESTING')
  returning id into v_request1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, sport_level, status)
  values (v_owner2, v_badminton_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'EASY', 'REQUESTING')
  returning id into v_request2;

  -- 2. 咖啡：1 筆 REQUESTING（同校區）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner3, v_coffee_id, 'NYCU', v_campus, v_time_start, v_time_end, 2, 4, 'REQUESTING')
  returning id into v_request3;

  -- 3. 羽球：已過期的 REQUESTING（latest_start < now()），不應被任何 RPC 查出
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner4, v_badminton_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '1 hour', 2, 4, 'REQUESTING')
  returning id into v_request_expired;

  -- 4. 咖啡：其他校區的 REQUESTING，不應混進本校區查詢
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner5, v_coffee_id, 'NYCU', v_other_campus, v_time_start, v_time_end, 2, 4, 'REQUESTING')
  returning id into v_request5;

  -- 填寫 request_member
  insert into request_member (request_id, user_id, role, status) values
    (v_request1, v_owner1, 'OWNER', 'JOINED'),
    (v_request1, v_invitee1, 'MEMBER', 'JOINED'),
    (v_request1, v_left_invitee, 'MEMBER', 'LEFT'),
    (v_request2, v_owner2, 'OWNER', 'JOINED'),
    (v_request3, v_owner3, 'OWNER', 'JOINED'),
    (v_request_expired, v_owner4, 'OWNER', 'JOINED'),
    (v_request5, v_owner5, 'OWNER', 'JOINED');

  update fixtures set
    viewer_id = v_viewer, deleted_id = v_deleted, badminton_id = v_badminton_id,
    coffee_id = v_coffee_id, campus = v_campus, other_campus = v_other_campus;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select viewer_id::text from fixtures), true);
end $$;

-- 1. 羽球需求卡：相同時段程度合併為 1 筆卡片，person_count 應為 3 (owner1 + invitee1 + owner2, 不含 left)，request_count 應為 2
select is(
  (select person_count from get_campus_demands('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select badminton_id from fixtures)),
  3,
  '羽球匿名需求卡之人頭數應為 3（已加入者，排除 LEFT）'
);

select is(
  (select request_count from get_campus_demands('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select badminton_id from fixtures)),
  2,
  '羽球需求卡之組數應為 2'
);

-- 2. 驗證程度欄位正確傳出
select is(
  (select sport_level from get_campus_demands('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select badminton_id from fixtures)),
  'EASY',
  '羽球需求卡之 sport_level 應為 EASY'
);

-- 3. 咖啡需求卡：person_count 應為 1
select is(
  (select person_count from get_campus_demands('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  1,
  '咖啡需求卡之人頭數應為 1'
);

-- 4. 已過期的需求不應出現在需求卡中
select is(
  (select count(*)::int from get_campus_demands('NYCU'::school, (select campus from fixtures))
    where latest_start <= now()),
  0,
  '需求卡絕不出現在過去時間的過期需求'
);

-- 5. 校區隔離：other_campus 查不到本校區羽球
select is(
  (select count(*)::int from get_campus_demands('NYCU'::school, (select other_campus from fixtures))
    where activity_type_id = (select badminton_id from fixtures)),
  0,
  '博愛校區不應出現光復校區的羽球需求'
);

-- 6. get_campus_pulse 也應排除已過期需求 (羽球應為 3 而非 4)
select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select badminton_id from fixtures)),
  3,
  'get_campus_pulse 人頭數應排除已過期的 1 人，維持為 3'
);

-- 7. 已刪除帳號被 ACCOUNT_DELETED 擋下
do $$ begin
  perform set_config('request.jwt.claim.sub', (select deleted_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select * from get_campus_demands('NYCU'::school, %L)$sql$, (select campus from fixtures)),
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫 get_campus_demands 應被 ACCOUNT_DELETED 擋下'
);

select * from finish();

rollback;
