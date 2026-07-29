-- =============================================================================
-- pgTAP Test — get_activity_member_profiles (docs/API.md §6.1.1, v1.23)
-- =============================================================================
-- Covers the gap found while scoping "我的活動" round 3 (UI_PLAN §4.1 Tab 2
-- 「成員」): the member list needs school/department/degree_level/reliability
-- tier for every member, but get_activity_contacts
-- (20260724120500_rpc_activity_and_contacts.sql) only ever returned
-- display_name/avatar_url/role/contacts, and app_user's own_profile_select
-- RLS blocks a direct read of another member's row. This is the first test
-- coverage for the new RPC added in 20260724125700_activity_member_profiles.sql.
--
-- Assertions: every member (self included) gets their real school/department/
-- degree_level/reliability_tier back, a CANCELLED member is still included
-- (mirrors get_activity_contacts's no-filter behaviour), a non-member caller
-- gets NOT_ACTIVITY_MEMBER, and the response never includes display_name/
-- avatar_url/contacts (those stay get_activity_contacts's job — no field
-- duplication between the two RPCs).
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup — a MATCHED activity with two JOINED members + one CANCELLED
--    member, plus an unrelated stranger.
-- -----------------------------------------------------------------------------

create temp table fixtures (
  member_a_id uuid,
  member_b_id uuid,
  cancelled_member_id uuid,
  stranger_id uuid,
  activity_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := 'AMP測試區';
  v_now         timestamptz := now();
  v_a           uuid := gen_random_uuid();
  v_b           uuid := gen_random_uuid();
  v_cancelled   uuid := gen_random_uuid();
  v_stranger    uuid := gen_random_uuid();
  v_req         match_request;
  v_activity    activity;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into auth.users (id, email) values
    (v_a, 'amp_a@nycu.edu.tw'),
    (v_b, 'amp_b@nycu.edu.tw'),
    (v_cancelled, 'amp_cancelled@nycu.edu.tw'),
    (v_stranger, 'amp_stranger@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, department, contact_line) values
    (v_a, 'amp_a@nycu.edu.tw', 'NYCU', 'AMP Member A', 'https://avatar.amp_a', 'MASTER', '資工', 'amp_a_line'),
    (v_b, 'amp_b@nycu.edu.tw', 'NYCU', 'AMP Member B', 'https://avatar.amp_b', 'PHD', '應數', 'amp_b_line'),
    (v_cancelled, 'amp_cancelled@nycu.edu.tw', 'NYCU', 'AMP Cancelled', 'https://avatar.amp_cancelled', 'UNDERGRAD', '物理', 'amp_cancelled_line'),
    (v_stranger, 'amp_stranger@nycu.edu.tw', 'NYCU', 'AMP Stranger', 'https://avatar.amp_stranger', 'MASTER', null, 'amp_stranger_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_a, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 4, 'MATCHED')
  returning * into v_req;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, v_now + interval '1 hour', v_now + interval '2 hours', 'MATCHED')
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_activity.id, v_a, v_req.id, 'JOINED'),
    (v_activity.id, v_b, v_req.id, 'JOINED'),
    (v_activity.id, v_cancelled, v_req.id, 'CANCELLED');

  update fixtures set member_a_id = v_a, member_b_id = v_b, cancelled_member_id = v_cancelled,
    stranger_id = v_stranger, activity_id = v_activity.id;
end;
$setup$;

grant select on fixtures to authenticated;

set local role authenticated;

-- -----------------------------------------------------------------------------
-- 1. A JOINED member sees every member's real profile fields, including their
--    own, and the CANCELLED member is not filtered out.
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member_a_id::text from fixtures), true);
end $$;

select is(
  (
    select elem->>'degree_level'
    from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
    where elem->>'user_id' = (select member_b_id::text from fixtures)
  ),
  'PHD',
  'member A 應看到 member B 真實的 degree_level'
);

select is(
  (
    select elem->>'department'
    from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
    where elem->>'user_id' = (select member_a_id::text from fixtures)
  ),
  '資工',
  'member A 應看到自己（呼叫者本人）也在名單裡，department 正確'
);

select is(
  (
    select count(*)::int
    from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
    where elem->>'user_id' = (select cancelled_member_id::text from fixtures)
  ),
  1,
  'CANCELLED 成員仍應出現在名單裡（跟 get_activity_contacts 不過濾 status 一致）'
);

select is(
  jsonb_array_length(get_activity_member_profiles((select activity_id from fixtures))),
  3,
  '名單應含全部 3 位成員（2 JOINED + 1 CANCELLED）'
);

-- -----------------------------------------------------------------------------
-- 2. 回傳不應包含 display_name/avatar_url/contacts — 那些留給
--    get_activity_contacts，避免兩支 RPC 欄位重複。
-- -----------------------------------------------------------------------------

select ok(
  not (
    (
      select elem
      from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
      where elem->>'user_id' = (select member_a_id::text from fixtures)
    ) ? 'display_name'
  ),
  '回傳不應包含 display_name（由 get_activity_contacts 負責，避免重複欄位）'
);

select ok(
  not (
    (
      select elem
      from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
      where elem->>'user_id' = (select member_a_id::text from fixtures)
    ) ? 'contacts'
  ),
  '回傳不應包含 contacts'
);

-- -----------------------------------------------------------------------------
-- 3. 非該活動成員 → NOT_ACTIVITY_MEMBER
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select throws_matching(
  format('select get_activity_member_profiles(%L::uuid)', (select activity_id from fixtures)),
  'NOT_ACTIVITY_MEMBER',
  '非該活動成員呼叫應回 NOT_ACTIVITY_MEMBER'
);

-- -----------------------------------------------------------------------------
-- 4. 不存在的 activity_id → NOT_FOUND
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member_a_id::text from fixtures), true);
end $$;

select throws_matching(
  'select get_activity_member_profiles(gen_random_uuid())',
  'NOT_FOUND',
  '不存在的 activity_id 應回 NOT_FOUND'
);

reset role;

select * from finish();

rollback;
