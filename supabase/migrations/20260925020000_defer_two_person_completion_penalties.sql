-- A two-person accusation must not impose a penalty before the other member
-- can respond. Preserve the existing quorum for larger activities.
-- Record which activity caused an automatic suspension so reconciliation never
-- clears an unrelated or legacy (unknown-source) suspension.
alter table app_user
  add column suspension_source_activity_id uuid references activity(id) on delete set null;

create index idx_reliability_settlement_activity
  on user_reliability_event (activity_id)
  where event_type in ('ATTENDED', 'NO_SHOW');

create or replace function fn_reconcile_completion_report(
  p_activity_id uuid,
  p_only_if_unsettled boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity_status activity_status;
  v_window_end timestamptz;
  v_total_members int;
  v_report_count int;
  v_quorum int;
  v_rec record;
  v_no_show_cnt int;
  v_is_mutual_accusation boolean := false;
begin
  -- Also serializes the cron path against a member's final report.
  select status, greatest(contact_visible_until, start_time + interval '24 hours')
    into v_activity_status, v_window_end
    from activity where id = p_activity_id for update;
  if not found or v_activity_status not in ('ONGOING', 'COMPLETED') then
    return false;
  end if;

  select count(*) into v_total_members from activity_member
   where activity_id = p_activity_id and status = 'JOINED';
  select count(*) into v_report_count from completion_report
   where activity_id = p_activity_id;
  v_quorum := ceil(v_total_members::numeric / 2.0);

  if v_report_count < v_quorum then return false; end if;
  if v_total_members = 2 and v_report_count < 2 and now() <= v_window_end then
    return false;
  end if;
  if p_only_if_unsettled and exists (
    select 1 from user_reliability_event
     where activity_id = p_activity_id and event_type in ('ATTENDED', 'NO_SHOW')
  ) then
    return true;
  end if;

  if v_activity_status = 'ONGOING' then
    update activity set status = 'COMPLETED' where id = p_activity_id;
  end if;

  -- Undo only a suspension explicitly attributed to this activity.
  update app_user
     set suspended_until = null, suspension_source_activity_id = null
   where suspension_source_activity_id = p_activity_id;
  delete from user_reliability_event
   where activity_id = p_activity_id and event_type in ('ATTENDED', 'NO_SHOW');

  if v_total_members = 2 and v_report_count = 2 then
    select count(*) = 2 into v_is_mutual_accusation
      from activity_member am
     where am.activity_id = p_activity_id and am.status = 'JOINED'
       and exists (
         select 1 from completion_report cr
          where cr.activity_id = p_activity_id
            and cr.reporter_id = am.user_id
            and cr.result = 'REPORTED_ABSENT'
            and exists (
              select 1 from activity_member other
               where other.activity_id = p_activity_id
                 and other.status = 'JOINED'
                 and other.user_id <> am.user_id
                 and other.user_id = any(cr.absent_user_ids)
            )
       );
  end if;

  for v_rec in (
    select user_id from activity_member
     where activity_id = p_activity_id and status = 'JOINED'
  ) loop
    select count(*) into v_no_show_cnt
      from completion_report cr, unnest(cr.absent_user_ids) uid
     where cr.activity_id = p_activity_id and uid = v_rec.user_id;

    if v_is_mutual_accusation then
      -- Two opposing accusations: neither member receives an attendance event.
      continue;
    elsif v_no_show_cnt >= v_quorum then
      insert into user_reliability_event (user_id, activity_id, event_type)
      values (v_rec.user_id, p_activity_id, 'NO_SHOW');
      if (
        select count(*) from (
          select event_type from user_reliability_event
           where user_id = v_rec.user_id order by created_at desc, id desc limit 3
        ) recent where event_type = 'NO_SHOW'
      ) = 3 then
        update app_user
           set suspended_until = now() + interval '7 days',
               suspension_source_activity_id = p_activity_id
         where id = v_rec.user_id;
      end if;
    else
      insert into user_reliability_event (user_id, activity_id, event_type)
      values (v_rec.user_id, p_activity_id, 'ATTENDED');
    end if;
  end loop;
  return true;
end;
$$;

revoke all on function fn_reconcile_completion_report(uuid, boolean)
  from public, anon, authenticated;
grant execute on function fn_reconcile_completion_report(uuid, boolean)
  to service_role;

create or replace function submit_completion_report(
  p_activity_id uuid,
  p_result completion_result,
  p_absent_user_ids uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_activity_status activity_status;
  v_start_time timestamptz;
  v_contact_visible_until timestamptz;
  v_settled boolean;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select status, start_time, contact_visible_until
    into v_activity_status, v_start_time, v_contact_visible_until
    from activity where id = p_activity_id for update;
  if not found then raise exception using message = 'NOT_FOUND'; end if;
  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;
  if v_activity_status in ('MATCHED', 'CANCELLED') then
    raise exception using message = 'ACTIVITY_NOT_ENDED';
  end if;
  if now() > greatest(coalesce(v_contact_visible_until, v_start_time + interval '24 hours'),
                      v_start_time + interval '24 hours') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  if coalesce(cardinality(p_absent_user_ids), 0) <>
     (select count(distinct uid) from unnest(coalesce(p_absent_user_ids, '{}')) as uid) then
    raise exception using message = 'INVALID_ABSENT_TARGET';
  end if;
  if (p_result = 'REPORTED_ABSENT' and coalesce(cardinality(p_absent_user_ids), 0) = 0)
     or (p_result <> 'REPORTED_ABSENT' and coalesce(cardinality(p_absent_user_ids), 0) > 0) then
    raise exception using message = 'INVALID_ABSENT_TARGET';
  end if;
  if p_absent_user_ids is not null and array_length(p_absent_user_ids, 1) > 0 then
    if v_user_id = any(p_absent_user_ids) then
      raise exception using message = 'INVALID_ABSENT_TARGET';
    end if;
    if exists (
      select 1 from unnest(p_absent_user_ids) as uid
       where uid is null or not exists (
         select 1 from activity_member
          where activity_id = p_activity_id and user_id = uid and status = 'JOINED'
       )
    ) then
      raise exception using message = 'INVALID_ABSENT_TARGET';
    end if;
  end if;

  begin
    insert into completion_report (activity_id, reporter_id, result, absent_user_ids)
    values (p_activity_id, v_user_id, p_result, coalesce(p_absent_user_ids, '{}'));
  exception when unique_violation then
    raise exception using message = 'ALREADY_REPORTED';
  end;

  v_settled := fn_reconcile_completion_report(p_activity_id);
  return jsonb_build_object('success', true, 'settled', v_settled);
end;
$$;

-- The existing 15-minute cron now also finalizes a one-report, two-person
-- activity after its reporting window; zero-report activities stay unpenalized.
create or replace function fn_complete_activities()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_activity_id uuid;
begin
  update activity set status = 'COMPLETED'
   where status = 'ONGOING' and start_time + interval '24 hours' < now();
  get diagnostics v_count = row_count;

  for v_activity_id in (
    select a.id from activity a
     where a.status = 'COMPLETED'
       and now() > greatest(a.contact_visible_until, a.start_time + interval '24 hours')
       and (select count(*) from activity_member am
             where am.activity_id = a.id and am.status = 'JOINED') = 2
       and (select count(*) from completion_report cr
             where cr.activity_id = a.id) = 1
       and not exists (
         select 1 from user_reliability_event e
          where e.activity_id = a.id and e.event_type in ('ATTENDED', 'NO_SHOW')
       )
  ) loop
    perform fn_reconcile_completion_report(v_activity_id, true);
  end loop;
  return v_count;
end;
$$;
