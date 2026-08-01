-- =============================================================================
-- pgTAP Test — Achievement Badges (get_my_badges) — v1.29
--
-- 涵蓋：
-- 1. 零資料的使用者：四個徽章皆未達成
-- 2. FIRST_ACTIVITY：恰好 1 次 ATTENDED 即達成
-- 3. PUNCTUAL：3 次 ATTENDED + 0 次 NO_SHOW 才達成；未達成邊界（3 次但有 1 次 NO_SHOW）
-- 4. GREAT_COMPANY：雙向 rematch_vote 才算，單向不算
-- 5. ENTHUSIASTIC_ORGANIZER：自己發起且 MATCHED 的 Request 達 3 筆才達成；2 筆不算
-- 6. 別人的資料不應混進自己的計算
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
  zero_id     uuid,  -- 零資料
  first_id    uuid,  -- 恰好 1 次 ATTENDED
  punctual_id uuid,  -- 3 次 ATTENDED，0 次 NO_SHOW
  noshow_id   uuid,  -- 3 次 ATTENDED，1 次 NO_SHOW（不應得 PUNCTUAL）
  mutual_a_id uuid,  -- 雙向 rematch
  mutual_b_id uuid,
  oneway_id   uuid,  -- 單向 rematch（不應得 GREAT_COMPANY）
  oneway_target_id uuid,
  organizer3_id uuid, -- 3 筆 MATCHED owner
  organizer2_id uuid, -- 2 筆 MATCHED owner（不應得徽章）
  act_type_id uuid,
  campus      text,
  dummy_activity_id uuid
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_zero uuid := gen_random_uuid();
  v_first uuid := gen_random_uuid();
  v_punctual uuid := gen_random_uuid();
  v_noshow uuid := gen_random_uuid();
  v_mutual_a uuid := gen_random_uuid();
  v_mutual_b uuid := gen_random_uuid();
  v_oneway uuid := gen_random_uuid();
  v_oneway_target uuid := gen_random_uuid();
  v_organizer3 uuid := gen_random_uuid();
  v_organizer2 uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus text := 'AB測試區';
  v_dummy_activity activity;
  v_rematch_activity activity;
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into auth.users (id, email)
  select u, u::text || '@nycu.edu.tw'
    from unnest(array[v_zero, v_first, v_punctual, v_noshow, v_mutual_a, v_mutual_b, v_oneway, v_oneway_target, v_organizer3, v_organizer2]) as u;
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  select u, u::text || '@nycu.edu.tw', 'NYCU', 'AB ' || u::text, 'https://avatar.ab', 'UNDERGRAD', 'ab_ig'
    from unnest(array[v_zero, v_first, v_punctual, v_noshow, v_mutual_a, v_mutual_b, v_oneway, v_oneway_target, v_organizer3, v_organizer2]) as u;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 'COMPLETED')
  returning * into v_dummy_activity;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 'COMPLETED')
  returning * into v_rematch_activity;

  -- 2. first：恰好 1 次 ATTENDED
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_first, v_dummy_activity.id, 'ATTENDED');

  -- 3. punctual：3 次 ATTENDED，0 次 NO_SHOW
  insert into user_reliability_event (user_id, activity_id, event_type)
  select v_punctual, v_dummy_activity.id, 'ATTENDED' from generate_series(1, 3);

  -- noshow：3 次 ATTENDED + 1 次 NO_SHOW（不應得 PUNCTUAL，但應得 FIRST_ACTIVITY）
  insert into user_reliability_event (user_id, activity_id, event_type)
  select v_noshow, v_dummy_activity.id, 'ATTENDED' from generate_series(1, 3);
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_noshow, v_dummy_activity.id, 'NO_SHOW');

  -- 4. mutual_a <-> mutual_b 雙向 rematch
  insert into rematch_vote (activity_id, from_user_id, to_user_id) values
    (v_rematch_activity.id, v_mutual_a, v_mutual_b),
    (v_rematch_activity.id, v_mutual_b, v_mutual_a);

  -- oneway -> oneway_target 單向，不應成立
  insert into rematch_vote (activity_id, from_user_id, to_user_id) values
    (v_rematch_activity.id, v_oneway, v_oneway_target);

  -- 5. organizer3：3 筆自己發起且 MATCHED 的 Request
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  select v_organizer3, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED'
    from generate_series(1, 3);

  -- organizer2：只有 2 筆，不應得徽章
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  select v_organizer2, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED'
    from generate_series(1, 2);

  update fixtures set
    zero_id = v_zero, first_id = v_first, punctual_id = v_punctual, noshow_id = v_noshow,
    mutual_a_id = v_mutual_a, mutual_b_id = v_mutual_b, oneway_id = v_oneway, oneway_target_id = v_oneway_target,
    organizer3_id = v_organizer3, organizer2_id = v_organizer2,
    act_type_id = v_act_type_id, campus = v_campus, dummy_activity_id = v_dummy_activity.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 零資料的使用者：四個徽章皆未達成
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select zero_id::text from fixtures), true);
end $$;

select is(
  (select count(*)::int from get_my_badges() where earned),
  0,
  '零資料的使用者不應達成任何徽章'
);

-- -----------------------------------------------------------------------------
-- 2. FIRST_ACTIVITY
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select first_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'FIRST_ACTIVITY'),
  true,
  '恰好 1 次 ATTENDED 應達成 FIRST_ACTIVITY'
);

select is(
  (select earned from get_my_badges() where badge_code = 'PUNCTUAL'),
  false,
  '恰好 1 次 ATTENDED 不應達成 PUNCTUAL（需要 3 次）'
);

-- -----------------------------------------------------------------------------
-- 3. PUNCTUAL 邊界
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select punctual_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'PUNCTUAL'),
  true,
  '3 次 ATTENDED、0 次 NO_SHOW 應達成 PUNCTUAL'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select noshow_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'PUNCTUAL'),
  false,
  '3 次 ATTENDED 但有 1 次 NO_SHOW 不應達成 PUNCTUAL'
);

-- -----------------------------------------------------------------------------
-- 4. GREAT_COMPANY：雙向才算
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select mutual_a_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'GREAT_COMPANY'),
  true,
  '雙向成立的 rematch_vote 應達成 GREAT_COMPANY'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select oneway_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'GREAT_COMPANY'),
  false,
  '單向的 rematch_vote 不應達成 GREAT_COMPANY'
);

-- -----------------------------------------------------------------------------
-- 5. ENTHUSIASTIC_ORGANIZER
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select organizer3_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'ENTHUSIASTIC_ORGANIZER'),
  true,
  '自己發起且 MATCHED 的 Request 達 3 筆應達成 ENTHUSIASTIC_ORGANIZER'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select organizer2_id::text from fixtures), true);
end $$;

select is(
  (select earned from get_my_badges() where badge_code = 'ENTHUSIASTIC_ORGANIZER'),
  false,
  '只有 2 筆不應達成 ENTHUSIASTIC_ORGANIZER'
);

select * from finish();

rollback;
