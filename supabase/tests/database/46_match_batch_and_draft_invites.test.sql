begin;
create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;
select plan(12);

create temp table match_batch_fixture (
  user_id uuid, request_id uuid, campus text, invite_token text
);

do $setup$
declare
  v_type uuid;
  v_user uuid;
  v_request uuid;
  v_campus text;
  v_token text;
begin
  select id into v_type from activity_type where name = '跑步' limit 1;
  for i in 1..8 loop
    v_user := gen_random_uuid();
    v_campus := case when i <= 3 then 'BATCH_THREE_46'
                     when i <= 7 then 'BATCH_FOUR_46'
                     else 'DRAFT_INVITE_46' end;
    insert into auth.users(id, email) values
      (v_user, 'batch46_' || i || '@nycu.edu.tw');
    insert into app_user(id, email, school, display_name, avatar_url,
                         degree_level, contact_ig) values
      (v_user, 'batch46_' || i || '@nycu.edu.tw', 'NYCU',
       'Batch ' || i, 'https://avatar.example/' || i, 'UNDERGRAD', 'batch46_' || i);
    v_token := case when i = 8 then 'draft-invite-46' else null end;
    insert into match_request(owner_id, activity_type_id, school, campus,
      earliest_start, latest_start, min_participants, max_participants,
      status, invite_token, created_at)
    values (v_user, v_type, 'NYCU', v_campus, now(), now() + interval '2 hours',
      case when i = 8 then 3 else 2 end, 3,
      case when i = 8 then 'DRAFT'::request_status else 'REQUESTING'::request_status end,
      v_token, now() - interval '1 hour' + i * interval '1 second')
    returning id into v_request;
    insert into request_member(request_id, user_id, role, status)
      values (v_request, v_user, 'OWNER', 'JOINED');
    insert into match_batch_fixture values(v_user, v_request, v_campus, v_token);
  end loop;
end;
$setup$;

select is((select count(*)::int from match_request where campus = 'DRAFT_INVITE_46' and status = 'DRAFT'),
          1, 'Invitation request remains a draft before the owner enters the waiting room');

do $invite$
declare
  v_friend uuid := gen_random_uuid();
begin
  insert into auth.users(id, email) values (v_friend, 'batch46_friend@nycu.edu.tw');
  insert into app_user(id, email, school, display_name, avatar_url,
                       degree_level, contact_ig) values
    (v_friend, 'batch46_friend@nycu.edu.tw', 'NYCU', 'Friend',
     'https://avatar.example/friend', 'UNDERGRAD', 'batch46_friend');
  perform set_config('request.jwt.claim.sub', v_friend::text, true);
  perform join_request_by_token('draft-invite-46');
  perform set_config('request.jwt.claim.sub', '', true);
end;
$invite$;

select is((select count(*)::int from request_member rm
  join match_request mr on mr.id = rm.request_id
  where mr.campus = 'DRAFT_INVITE_46' and rm.status = 'JOINED'),
  2, 'Friend joins before automatic matching starts');

do $submit$
begin
  perform set_config('request.jwt.claim.sub',
    (select user_id::text from match_batch_fixture where campus = 'DRAFT_INVITE_46'), true);
  perform submit_request(
    (select request_id from match_batch_fixture where campus = 'DRAFT_INVITE_46'));
  perform set_config('request.jwt.claim.sub', '', true);
end;
$submit$;

select is((select status::text from match_request where campus = 'DRAFT_INVITE_46'),
  'REQUESTING', 'Owner explicitly submits the draft after friends join');

select ok((select revoked_at is not null from match_request
  where campus = 'DRAFT_INVITE_46'),
  'Entering the waiting room closes the invitation code');

select ok((select matching_ready_at > now() - interval '30 seconds'
  from match_request where campus = 'DRAFT_INVITE_46'),
  'The collection window starts when the owner submits, not when the draft was created');

select is((select fn_run_matching_engine()), 3,
  'Three compatible people form one activity; four form two confirmations');

select is((select status::text from match_request where campus = 'DRAFT_INVITE_46'),
  'REQUESTING', 'A new two-person request waits for the third person instead of matching instantly');

select is((select count(*)::int from activity a
  join activity_member am on am.activity_id = a.id
  where a.campus = 'BATCH_THREE_46' and am.status = 'JOINED'),
  3, 'All three compatible people enter the same activity');

select is((select count(*)::int from match_request
  where campus = 'BATCH_FOUR_46' and status = 'PENDING_CONFIRMATION'),
  4, 'Four people with maximum three are split 2+2, leaving nobody unmatched');

create temp table confirmation_result(first_response text, final_status text);
do $confirm$
declare
  v_pc pending_confirmation;
  v_owner_a uuid;
  v_owner_b uuid;
  v_first_response text;
  v_final_status text;
begin
  select pc.* into v_pc from pending_confirmation pc
  join match_request mr on mr.id = pc.request_a_id
  where mr.campus = 'BATCH_FOUR_46' limit 1;
  select owner_id into v_owner_a from match_request where id = v_pc.request_a_id;
  select owner_id into v_owner_b from match_request where id = v_pc.request_b_id;
  perform set_config('request.jwt.claim.sub', v_owner_a::text, true);
  perform respond_pending_confirmation(v_pc.id, true);
  v_first_response := get_pending_confirmation_status(v_pc.request_a_id)->>'own_response';
  perform set_config('request.jwt.claim.sub', v_owner_b::text, true);
  perform respond_pending_confirmation(v_pc.id, true);
  perform set_config('request.jwt.claim.sub', v_owner_a::text, true);
  v_final_status := get_pending_confirmation_status(v_pc.request_a_id)->>'status';
  perform set_config('request.jwt.claim.sub', '', true);
  insert into confirmation_result values(v_first_response, v_final_status);
end;
$confirm$;

select is((select first_response from confirmation_result), 'CONFIRMED',
  'The confirmation status reports the caller own accepted response');
select is((select final_status from confirmation_result), 'CONFIRMED',
  'Both accepted responses resolve to confirmed, never failed');
select is((select count(*)::int from activity_member am
  join activity a on a.id = am.activity_id
  where a.campus = 'BATCH_FOUR_46' and am.status = 'JOINED'),
  2, 'Both confirmed participants enter the same activity');

select finish();
rollback;
