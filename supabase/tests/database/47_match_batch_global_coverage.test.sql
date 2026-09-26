begin;
create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;
select plan(6);

create temp table coverage_fixture(label text primary key, request_id uuid);
do $setup$
declare
  v_type uuid;
  v_user uuid;
  v_request uuid;
  v_level text;
begin
  select id into v_type from activity_type where name = '羽球' limit 1;
  for i in 1..4 loop
    v_user := gen_random_uuid();
    v_level := case i when 1 then 'LEVEL_6_7'
                      when 3 then 'LEVEL_8_10'
                      else 'LEVEL_1_5' end;
    insert into auth.users(id, email)
      values (v_user, 'coverage47_' || i || '@nycu.edu.tw');
    insert into app_user(id, email, school, display_name, avatar_url,
                         degree_level, contact_ig)
      values (v_user, 'coverage47_' || i || '@nycu.edu.tw', 'NYCU',
              'Coverage ' || i, 'https://avatar.example/' || i,
              'UNDERGRAD', 'coverage47_' || i);
    insert into match_request(owner_id, activity_type_id, school, campus,
      earliest_start, latest_start, min_participants, max_participants,
      status, sport_level, created_at)
      values (v_user, v_type, 'NYCU', 'COVERAGE_GLOBAL_47',
              now(), now() + interval '2 hours', 2, 2,
              'REQUESTING', v_level, now() - interval '1 hour' + i * interval '1 second')
      returning id into v_request;
    insert into request_member(request_id, user_id, role, status)
      values (v_request, v_user, 'OWNER', 'JOINED');
    insert into coverage_fixture values (chr(64 + i), v_request);
  end loop;
end;
$setup$;

-- A-B is the oldest viable pair, but it strands C and D. A-C plus B-D
-- covers everyone. The engine must optimize the batch, not the first pair.
select is(fn_run_matching_engine(), 2,
  'The whole compatible batch creates two groups');

select is((select count(*)::integer from match_request
  where campus = 'COVERAGE_GLOBAL_47' and status = 'PENDING_CONFIRMATION'),
  4, 'No one is left waiting when two compatible pairs exist');

select ok(exists (
  select 1 from pending_confirmation pc
  where (pc.request_a_id = (select request_id from coverage_fixture where label = 'A')
         and pc.request_b_id = (select request_id from coverage_fixture where label = 'C'))
     or (pc.request_b_id = (select request_id from coverage_fixture where label = 'A')
         and pc.request_a_id = (select request_id from coverage_fixture where label = 'C'))
), 'A joins C rather than taking B away from D');

select ok(exists (
  select 1 from pending_confirmation pc
  where (pc.request_a_id = (select request_id from coverage_fixture where label = 'B')
         and pc.request_b_id = (select request_id from coverage_fixture where label = 'D'))
     or (pc.request_b_id = (select request_id from coverage_fixture where label = 'B')
         and pc.request_a_id = (select request_id from coverage_fixture where label = 'D'))
), 'B joins D, completing coverage of the batch');

do $twelve$
declare
  v_type uuid;
  v_user uuid;
  v_request uuid;
begin
  select id into v_type from activity_type where name = '跑步' limit 1;
  for i in 1..12 loop
    v_user := gen_random_uuid();
    insert into auth.users(id, email)
      values (v_user, 'coverage47_large_' || i || '@nycu.edu.tw');
    insert into app_user(id, email, school, display_name, avatar_url,
                         degree_level, contact_ig)
      values (v_user, 'coverage47_large_' || i || '@nycu.edu.tw', 'NYCU',
              'Coverage large ' || i, 'https://avatar.example/large/' || i,
              'UNDERGRAD', 'coverage47_large_' || i);
    insert into match_request(owner_id, activity_type_id, school, campus,
      earliest_start, latest_start, min_participants, max_participants,
      status, created_at)
      values (v_user, v_type, 'NYCU', 'COVERAGE_TWELVE_47',
              now(), now() + interval '2 hours', 2, 3,
              'REQUESTING', now() - interval '1 hour' + i * interval '1 second')
      returning id into v_request;
    insert into request_member(request_id, user_id, role, status)
      values (v_request, v_user, 'OWNER', 'JOINED');
  end loop;
end;
$twelve$;

select is(fn_run_matching_engine(), 4,
  'Twelve compatible people form four groups within the exact batch limit');
select is((select count(*)::integer from activity_member am
  join activity a on a.id = am.activity_id
  where a.campus = 'COVERAGE_TWELVE_47' and am.status = 'JOINED'),
  12, 'The larger batch leaves no one waiting');

select * from finish();
rollback;
