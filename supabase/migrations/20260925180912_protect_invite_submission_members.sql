-- A friend may join a draft before its owner submits it. Recheck every member
-- atomically at that submit boundary so another request cannot claim them.
create or replace function guard_invite_request_submission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'DRAFT' and new.status = 'REQUESTING' then
    new.matching_ready_at := now();
    if new.latest_start <= now() then
      raise exception using message = 'INVALID_INPUT', detail = 'WINDOW_IN_PAST';
    end if;
    if exists (
      select 1 from request_member rm
      join request_member other_rm on other_rm.user_id = rm.user_id
        and other_rm.status = 'JOINED' and other_rm.request_id <> new.id
      join match_request other_request on other_request.id = other_rm.request_id
      where rm.request_id = new.id and rm.status = 'JOINED'
        and other_request.status in ('REQUESTING', 'PENDING_CONFIRMATION')
    ) then
      raise exception using message = 'ALREADY_REQUESTING';
    end if;
    if exists (
      select 1 from request_member rm
      join activity_member am on am.user_id = rm.user_id and am.status = 'JOINED'
      join activity a on a.id = am.activity_id
      where rm.request_id = new.id and rm.status = 'JOINED'
        and a.status in ('MATCHED', 'ONGOING')
    ) then
      raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS';
    end if;
    -- Entering the waiting room closes the friend invitation window.
    if old.invite_token is not null then
      new.revoked_at := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger guard_invite_request_submission_trigger
before update of status on match_request
for each row execute function guard_invite_request_submission();

revoke execute on function guard_invite_request_submission() from public, anon, authenticated;
