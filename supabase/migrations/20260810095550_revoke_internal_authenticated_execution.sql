-- =============================================================================
-- Backfill authenticated EXECUTE revocation for existing projects
--
-- Some Supabase projects have an explicit authenticated grant in addition to
-- PostgreSQL's PUBLIC default. The preceding migration handles fresh builds;
-- this migration makes production environments with that legacy grant match
-- the same allow-list policy.
-- =============================================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
  loop
    execute format('revoke execute on function %s from authenticated', r.signature);
  end loop;

  for r in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and p.proname = any (array[
         'block_user', 'cancel_activity_participation', 'cancel_request',
         'check_enrollment_reminder', 'complete_profile', 'create_request',
         'delete_account', 'get_activity_contacts',
         'get_activity_member_profiles', 'get_campus_pulse',
         'get_my_badges', 'get_my_reliability',
         'get_or_create_invite_link',
         'get_pending_confirmation_candidate_info',
         'get_pending_confirmation_status', 'join_request_by_token',
         'leave_request', 'mark_arrived', 'propose_activity_location',
         'propose_activity_type', 'propose_location', 'rematch_vote',
         'respond_downgrade', 'respond_pending_confirmation',
         'revoke_invite_link', 'search_activity_type',
         'submit_completion_report', 'submit_feedback', 'submit_report',
         'submit_request', 'subscribe_activity_alert', 'unblock_user',
         'unsubscribe_activity_alert', 'update_meeting_hint',
         'update_meeting_point', 'update_vibe_tags', 'vote_activity_location'
       ])
  loop
    execute format('grant execute on function %s to authenticated', r.signature);
  end loop;
end;
$$;
