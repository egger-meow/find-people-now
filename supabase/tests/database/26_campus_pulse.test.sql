-- =============================================================================
-- pgTAP Test — Campus Activity Pulse (get_campus_pulse) — v1.26
--
-- 涵蓋：
-- 1. 只計算 REQUESTING（DRAFT/PENDING_CONFIRMATION/MATCHED 皆不計入）
-- 2. 正確依 (school, campus) 分組，不混到其他校區
-- 3. 同活動類型多筆 REQUESTING 正確加總
-- 4. 零筆的活動類型完全不出現在結果中（不是回傳 count=0）
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(4);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  viewer_id     uuid,
  basketball_id uuid,
  coffee_id     uuid,
  campus        text,
  other_campus  text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_viewer        uuid := gen_random_uuid();
  v_owner1        uuid := gen_random_uuid();
  v_owner2        uuid := gen_random_uuid();
  v_owner3        uuid := gen_random_uuid();
  v_owner4        uuid := gen_random_uuid();
  v_owner5        uuid := gen_random_uuid();
  v_basketball_id uuid;
  v_coffee_id     uuid;
  v_campus        text := 'CP測試區';
  v_other_campus  text := 'CP其他區';
begin
  select id into v_basketball_id from activity_type where name = '籃球' limit 1;
  select id into v_coffee_id from activity_type where name = '咖啡' limit 1;

  insert into auth.users (id, email) values
    (v_viewer, 'cp_viewer@nycu.edu.tw'), (v_owner1, 'cp_o1@nycu.edu.tw'),
    (v_owner2, 'cp_o2@nycu.edu.tw'), (v_owner3, 'cp_o3@nycu.edu.tw'), (v_owner4, 'cp_o4@nycu.edu.tw'),
    (v_owner5, 'cp_o5@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  select u, u::text || '@nycu.edu.tw', 'NYCU', 'CP ' || u::text, 'https://avatar.cp', 'UNDERGRAD', 'cp_ig'
    from unnest(array[v_viewer, v_owner1, v_owner2, v_owner3, v_owner4, v_owner5]) as u;

  -- 2 筆籃球 REQUESTING（同校區）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    (v_owner1, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING'),
    (v_owner2, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING');

  -- 1 筆咖啡 REQUESTING（同校區）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner3, v_coffee_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING');

  -- 1 筆咖啡 DRAFT（同校區，不應計入——未送出）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner4, v_coffee_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'DRAFT');

  -- 1 筆籃球 MATCHED（同校區，不應計入——已成局）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner1, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED');

  -- 1 筆籃球 REQUESTING（不同校區，不應計入這次查詢）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner5, v_basketball_id, 'NYCU', v_other_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING');

  update fixtures set
    viewer_id = v_viewer, basketball_id = v_basketball_id, coffee_id = v_coffee_id,
    campus = v_campus, other_campus = v_other_campus;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select viewer_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 籃球應為 2（只算 REQUESTING，MATCHED 不計入）
-- -----------------------------------------------------------------------------

select is(
  (select request_count from get_campus_pulse('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select basketball_id from fixtures)),
  2,
  '籃球 REQUESTING 應為 2，MATCHED 的那筆不計入'
);

-- -----------------------------------------------------------------------------
-- 2. 咖啡應為 1（DRAFT 不計入）
-- -----------------------------------------------------------------------------

select is(
  (select request_count from get_campus_pulse('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  1,
  '咖啡 REQUESTING 應為 1，DRAFT 的那筆不計入'
);

-- -----------------------------------------------------------------------------
-- 3. 不同校區的 REQUESTING 不應混進來——other_campus 查詢應只看到籃球 1 筆
-- -----------------------------------------------------------------------------

select is(
  (select request_count from get_campus_pulse('NYCU'::school, (select other_campus from fixtures))
    where activity_type_id = (select basketball_id from fixtures)),
  1,
  '不同校區應分開計算，other_campus 的籃球應為 1'
);

-- -----------------------------------------------------------------------------
-- 4. other_campus 查詢裡咖啡應完全不出現（零筆，不是 count=0 的一列）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from get_campus_pulse('NYCU'::school, (select other_campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  0,
  '零筆的活動類型完全不應出現在結果列中'
);

select * from finish();

rollback;
