-- =============================================================================
-- 向前修正 Migration (Forward Fixes)
--
-- 涵蓋：
-- 1. [P1] 推播清理 RPC 權限收緊：revoke cleanup_stale_push_subscriptions from authenticated
-- 2. [P1] 配對防重加固：單房自行成團與撮合均加入跨活動成員防重 (ACTIVE_ACTIVITY_IN_PROGRESS)
-- 3. [P1] fn_create_activity_from_requests 增加 distinct on (rm.user_id) 防重複 key
-- 4. [P2] 校園需求卡 get_campus_demands 人數分組向前落地
-- 5. [P2] 營運指標 get_pilot_operational_metrics 重複參與率修復（區分實際活動留存與需求留存）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 推播清理 RPC 權限修正
-- -----------------------------------------------------------------------------
revoke execute on function cleanup_stale_push_subscriptions(text[]) from public, anon, authenticated;
grant execute on function cleanup_stale_push_subscriptions(text[]) to service_role;

-- -----------------------------------------------------------------------------
-- 2. 校園需求卡向前修正（確保上下限分組）
-- -----------------------------------------------------------------------------
create or replace function get_campus_demands(
  p_school school,
  p_campus text default null
)
returns table (
  activity_type_id    uuid,
  activity_type_name  text,
  campus              text,
  earliest_start      timestamptz,
  latest_start        timestamptz,
  sport_level         text,
  sport_level_rating  int,
  study_target        text,
  min_participants    int,
  max_participants    int,
  person_count        int,
  request_count       int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  return query
    select
      mr.activity_type_id,
      at.name as activity_type_name,
      mr.campus,
      mr.earliest_start,
      mr.latest_start,
      mr.sport_level,
      mr.sport_level_rating,
      mr.study_target,
      mr.min_participants::int as min_participants,
      mr.max_participants::int as max_participants,
      count(distinct rm.user_id)::int as person_count,
      count(distinct mr.id)::int as request_count
    from match_request mr
    join activity_type at on at.id = mr.activity_type_id
    join request_member rm on rm.request_id = mr.id and rm.status = 'JOINED'
   where mr.status = 'REQUESTING'
     and mr.latest_start > now()
     and mr.school = p_school
     and (p_campus is null or mr.campus = p_campus)
   group by
     mr.activity_type_id,
     at.name,
     mr.campus,
     mr.earliest_start,
     mr.latest_start,
     mr.sport_level,
     mr.sport_level_rating,
     mr.study_target,
     mr.min_participants,
     mr.max_participants
   order by
     mr.earliest_start asc,
     count(distinct rm.user_id) desc;
end;
$$;

revoke execute on function get_campus_demands(school, text) from public, anon;
grant execute on function get_campus_demands(school, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. 配對防重：fn_create_activity_from_requests
-- -----------------------------------------------------------------------------
create or replace function fn_create_activity_from_requests(p_request_ids uuid[])
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity           activity;
  v_activity_type_id   uuid;
  v_school             school;
  v_campus             text;
  v_start_time         timestamptz;
  v_latest_min         timestamptz;
  v_req_min            int;
  v_req_max            int;
  v_total_joined       int;
  v_dur                int;
  v_found_count        int;
  v_bad_status_count   int;
begin
  if p_request_ids is null or array_length(p_request_ids, 1) < 1 then
    raise exception using message = 'INVALID_INPUT', detail = 'AT_LEAST_ONE_REQUEST_REQUIRED';
  end if;

  perform 1 from match_request where id = any(p_request_ids) for update;

  select count(*) into v_found_count from match_request where id = any(p_request_ids);
  if v_found_count <> array_length(p_request_ids, 1) then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_bad_status_count
    from match_request
   where id = any(p_request_ids)
     and status not in ('REQUESTING', 'PENDING_CONFIRMATION');
  if v_bad_status_count > 0 then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  if (select count(distinct (activity_type_id, school, campus)) from match_request where id = any(p_request_ids)) <> 1 then
    raise exception using message = 'INTERNAL_ERROR', detail = 'MISMATCHED_ACTIVITY_TYPE_OR_CAMPUS';
  end if;

  select activity_type_id, school, campus,
         max(earliest_start), min(latest_start),
         max(min_participants), min(max_participants)
    into v_activity_type_id, v_school, v_campus,
         v_start_time, v_latest_min,
         v_req_min, v_req_max
    from match_request
   where id = any(p_request_ids)
   group by activity_type_id, school, campus;

  select count(distinct rm.user_id) into v_total_joined
    from request_member rm
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED';

  if v_total_joined < v_req_min or (v_req_max is not null and v_total_joined > v_req_max) then
    raise exception using message = 'INTERNAL_ERROR', detail = 'HEADCOUNT_REQUIREMENTS_NOT_MET';
  end if;

  -- 跨活動成員防重檢查：任一成員不得已在進行中/成立中的活動
  if exists (
    select 1
      from request_member rm
      join activity_member am on am.user_id = rm.user_id
      join activity a on a.id = am.activity_id
     where rm.request_id = any(p_request_ids)
       and rm.status = 'JOINED'
       and am.status = 'JOINED'
       and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS', detail = 'MEMBER_ALREADY_IN_ACTIVE_ACTIVITY';
  end if;

  v_start_time := greatest(v_start_time, now());

  if v_start_time > v_latest_min then
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_activity_type_id;

  insert into activity (
    activity_type_id, school, campus, start_time, estimated_end_time,
    status, contact_visible_until
  ) values (
    v_activity_type_id, v_school, v_campus,
    v_start_time, v_start_time + (v_dur || ' minutes')::interval,
    'MATCHED', now() + interval '24 hours'
  )
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  select distinct on (rm.user_id) v_activity.id, rm.user_id, rm.request_id, 'JOINED'
    from request_member rm
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED'
   order by rm.user_id, rm.created_at asc;

  update match_request set status = 'MATCHED' where id = any(p_request_ids);

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
    from activity_member am where am.activity_id = v_activity.id;

  return v_activity;
end;
$$;

revoke execute on function fn_create_activity_from_requests(uuid[]) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. 配對防重：commit_match
-- -----------------------------------------------------------------------------
create or replace function commit_match(
  p_request_a_id uuid,
  p_request_b_id uuid
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req_a match_request;
  v_req_b match_request;
  v_total int;
  v_pc_id uuid;
begin
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_req_a.status <> 'REQUESTING' or v_req_b.status <> 'REQUESTING' then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  if v_req_a.activity_type_id <> v_req_b.activity_type_id
     or v_req_a.school <> v_req_b.school
     or v_req_a.campus <> v_req_b.campus then
    raise exception using message = 'INTERNAL_ERROR', detail = 'MISMATCHED_ACTIVITY_TYPE_OR_CAMPUS';
  end if;

  if greatest(v_req_a.earliest_start, v_req_b.earliest_start, now()) > least(v_req_a.latest_start, v_req_b.latest_start) then
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  -- 跨活動成員防重檢查：任一成員不得已在進行中/成立中的活動
  if exists (
    select 1
      from request_member rm
      join activity_member am on am.user_id = rm.user_id
      join activity a on a.id = am.activity_id
     where rm.request_id in (p_request_a_id, p_request_b_id)
       and rm.status = 'JOINED'
       and am.status = 'JOINED'
       and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS', detail = 'MEMBER_ALREADY_IN_ACTIVE_ACTIVITY';
  end if;

  select count(distinct user_id) into v_total
    from request_member
   where request_id in (p_request_a_id, p_request_b_id) and status = 'JOINED';

  if v_total > 2 then
    return fn_create_activity_from_requests(array[p_request_a_id, p_request_b_id]);
  else
    insert into pending_confirmation (
      request_a_id, request_b_id, confirm_window_expire_at, status
    ) values (
      p_request_a_id, p_request_b_id, now() + fn_get_config_interval('confirm_window_minutes'), 'PENDING'
    )
    returning id into v_pc_id;

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_a_id, 'pending_confirmation_id', v_pc_id)
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_b_id, 'pending_confirmation_id', v_pc_id)
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    return null;
  end if;
end;
$$;

revoke execute on function commit_match(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. 配對防重：fn_run_matching_engine
-- -----------------------------------------------------------------------------
create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group                  record;
  v_seed                   match_request;
  v_has_prev_seed          boolean;
  v_prev_seed_created_at    timestamptz;
  v_prev_seed_id           uuid;
  v_candidate              record;
  v_accum_ids              uuid[];
  v_accum_count            int;
  v_accum_earliest         timestamptz;
  v_accum_latest           timestamptz;
  v_accum_min_participants int;
  v_accum_max_participants int;
  v_new_earliest           timestamptz;
  v_new_latest             timestamptz;
  v_new_min_participants   int;
  v_new_max_participants   int;
  v_cand_count             int;
  v_match_count            int := 0;
  v_group_scan_budget      constant int := 5000;
  v_group_scans_used       int;
  v_act_level_system       level_system;
begin
  if not pg_try_advisory_xact_lock(45001, 1) then
    return 0;
  end if;

  <<group_loop>>
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
       and latest_start > now()
  ) loop
    v_has_prev_seed := false;
    v_group_scans_used := 0;

    select level_system into v_act_level_system
      from activity_type
     where id = v_group.activity_type_id;

    <<seed_loop>>
    loop
      if v_has_prev_seed then
        select * into v_seed
          from match_request
         where activity_type_id = v_group.activity_type_id
           and school = v_group.school
           and campus = v_group.campus
           and status = 'REQUESTING'
           and latest_start > now()
           and (created_at, id) > (v_prev_seed_created_at, v_prev_seed_id)
         order by created_at asc, id asc
         limit 1;
      else
        select * into v_seed
          from match_request
         where activity_type_id = v_group.activity_type_id
           and school = v_group.school
           and campus = v_group.campus
           and status = 'REQUESTING'
           and latest_start > now()
         order by created_at asc, id asc
         limit 1;
      end if;

      exit seed_loop when v_seed.id is null;

      v_prev_seed_created_at := v_seed.created_at;
      v_prev_seed_id := v_seed.id;
      v_has_prev_seed := true;

      -- 0. 跨活動防重檢查：若種子請求中已有成員在進行中/成立中的活動，跳過該種子
      if exists (
        select 1
          from request_member rm
          join activity_member am on am.user_id = rm.user_id
          join activity a on a.id = am.activity_id
         where rm.request_id = v_seed.id
           and rm.status = 'JOINED'
           and am.status = 'JOINED'
           and a.status in ('MATCHED', 'ONGOING')
      ) then
        continue;
      end if;

      select count(distinct user_id) into v_accum_count
        from request_member where request_id = v_seed.id and status = 'JOINED';

      v_accum_ids := array[v_seed.id];
      v_accum_earliest := v_seed.earliest_start;
      v_accum_latest := v_seed.latest_start;
      v_accum_min_participants := v_seed.min_participants;
      v_accum_max_participants := v_seed.max_participants;

      if v_accum_max_participants is null or v_accum_count < v_accum_max_participants then
        for v_candidate in (
          select r.* from match_request r
           where r.activity_type_id = v_group.activity_type_id
             and r.school = v_group.school
             and r.campus = v_group.campus
             and r.status = 'REQUESTING'
             and r.latest_start > now()
             and r.id <> v_seed.id
           order by r.created_at asc
        ) loop
          exit when v_group_scans_used >= v_group_scan_budget;
          exit when v_accum_count >= v_accum_min_participants and array_length(v_accum_ids, 1) >= 2;

          v_group_scans_used := v_group_scans_used + 1;

          if not exists (
            select 1 from match_request
             where id = v_candidate.id
               and status = 'REQUESTING'
               and latest_start > now()
          ) then
            continue;
          end if;

          if exists (
            select 1
              from request_member rm_acc
              join request_member rm_cand on rm_cand.user_id = rm_acc.user_id
             where rm_acc.request_id = any(v_accum_ids)
               and rm_acc.status = 'JOINED'
               and rm_cand.request_id = v_candidate.id
               and rm_cand.status = 'JOINED'
          ) then
            continue;
          end if;

          if exists (
            select 1
              from request_member rm_cand
              join activity_member am on am.user_id = rm_cand.user_id
              join activity a on a.id = am.activity_id
             where rm_cand.request_id = v_candidate.id
               and rm_cand.status = 'JOINED'
               and am.status = 'JOINED'
               and a.status in ('MATCHED', 'ONGOING')
          ) then
            continue;
          end if;

          if exists (
            select 1
              from request_member rm_acc
              cross join request_member rm_cand
              join user_block ub
                on (ub.blocker_id = rm_acc.user_id and ub.blocked_id = rm_cand.user_id)
                or (ub.blocker_id = rm_cand.user_id and ub.blocked_id = rm_acc.user_id)
             where rm_acc.request_id = any(v_accum_ids)
               and rm_acc.status = 'JOINED'
               and rm_cand.request_id = v_candidate.id
               and rm_cand.status = 'JOINED'
          ) then
            continue;
          end if;

          if exists (
            select 1
              from match_request mr_acc
              join match_history_avoidance mha
                on mha.user_a_id = least(mr_acc.owner_id, v_candidate.owner_id)
               and mha.user_b_id = greatest(mr_acc.owner_id, v_candidate.owner_id)
               and mha.expire_at > now()
             where mr_acc.id = any(v_accum_ids)
          ) then
            continue;
          end if;

          v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
          v_new_latest := least(v_accum_latest, v_candidate.latest_start);
          if v_new_earliest > v_new_latest or v_new_latest <= now() then
            continue;
          end if;

          -- 6. 活動等級相容性（與累積集合中每一個需求皆須相容，防止傳遞性破壞）
          if exists (
            select 1
              from match_request mr_acc
             where mr_acc.id = any(v_accum_ids)
               and not fn_sport_level_match(v_act_level_system, mr_acc.sport_level, v_candidate.sport_level)
          ) then
            continue;
          end if;

          if exists (
            select 1 from match_request mr_acc
             where mr_acc.id = any(v_accum_ids)
               and mr_acc.study_target_normalized is not null
               and v_candidate.study_target_normalized is not null
               and mr_acc.study_target_normalized <> v_candidate.study_target_normalized
          ) then
            continue;
          end if;

          select count(distinct user_id) into v_cand_count
            from request_member where request_id = v_candidate.id and status = 'JOINED';

          v_new_min_participants := greatest(v_accum_min_participants, v_candidate.min_participants);
          if v_accum_max_participants is null then
            v_new_max_participants := v_candidate.max_participants;
          elsif v_candidate.max_participants is null then
            v_new_max_participants := v_accum_max_participants;
          else
            v_new_max_participants := least(v_accum_max_participants, v_candidate.max_participants);
          end if;

          if v_new_max_participants is not null then
            if v_new_min_participants > v_new_max_participants then
              continue;
            end if;

            if v_accum_count + v_cand_count > v_new_max_participants then
              continue;
            end if;
          end if;

          v_accum_ids := v_accum_ids || v_candidate.id;
          v_accum_count := v_accum_count + v_cand_count;
          v_accum_earliest := v_new_earliest;
          v_accum_latest := v_new_latest;
          v_accum_min_participants := v_new_min_participants;
          v_accum_max_participants := v_new_max_participants;
        end loop;
      end if;

      if v_accum_count >= v_accum_min_participants
         and (v_accum_max_participants is null or v_accum_count <= v_accum_max_participants)
         and (array_length(v_accum_ids, 1) >= 2 or (array_length(v_accum_ids, 1) = 1 and v_accum_count > 2 and v_accum_count >= v_seed.min_participants))
      then
        if exists (
          select 1
            from request_member rm
            join activity_member am on am.user_id = rm.user_id
            join activity a on a.id = am.activity_id
           where rm.request_id = any(v_accum_ids)
             and rm.status = 'JOINED'
             and am.status = 'JOINED'
             and a.status in ('MATCHED', 'ONGOING')
        ) then
          continue;
        end if;

        begin
          if array_length(v_accum_ids, 1) = 1 or v_accum_count > 2 then
            perform fn_create_activity_from_requests(v_accum_ids);
          else
            perform commit_match(v_accum_ids[1], v_accum_ids[2]);
          end if;
          v_match_count := v_match_count + 1;
        exception
          when others then
            null;
        end;
      end if;

    end loop seed_loop;
  end loop group_loop;

  return v_match_count;
end;
$$;

revoke execute on function fn_run_matching_engine() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. 營運指標：get_pilot_operational_metrics（修復重複參與率計算）
-- -----------------------------------------------------------------------------
create or replace function get_pilot_operational_metrics(
  p_school school default 'NYCU',
  p_campus text default '光復',
  p_since timestamptz default (now() - interval '7 days'),
  p_until timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_demand_total int := 0;
  v_demand_matched int := 0;
  v_demand_expired int := 0;
  v_demand_cancelled int := 0;
  v_avg_wait numeric := null;
  v_median_wait numeric := null;

  v_act_total int := 0;
  v_act_completed int := 0;
  v_act_cancelled int := 0;
  v_act_ongoing int := 0;

  v_verified_attended int := 0;
  v_unverified_completion int := 0;
  v_no_show int := 0;

  v_unique_act_users int := 0;
  v_repeat_act_users int := 0;
  v_repeat_act_rate numeric := 0;

  v_unique_req_users int := 0;
  v_repeat_req_users int := 0;
  v_repeat_req_rate numeric := 0;

  v_total_reports int := 0;
  v_pending_reports int := 0;
  v_spam_reports int := 0;
  v_harass_reports int := 0;
  v_other_reports int := 0;
  v_feedbacks int := 0;
begin
  -- 1. 需求量與等待時間
  select
    count(*),
    count(*) filter (where status = 'MATCHED'),
    count(*) filter (where status = 'EXPIRED'),
    count(*) filter (where status = 'CANCELLED')
  into
    v_demand_total,
    v_demand_matched,
    v_demand_expired,
    v_demand_cancelled
  from match_request
  where created_at >= p_since and created_at <= p_until
    and (p_school is null or school = p_school)
    and (p_campus is null or campus = p_campus);

  with matched_waits as (
    select distinct r.id, extract(epoch from (a.created_at - r.created_at)) / 60.0 as wait_minutes
    from match_request r
    join activity_member am on am.source_request_id = r.id
    join activity a on a.id = am.activity_id
    where r.status = 'MATCHED'
      and r.created_at >= p_since and r.created_at <= p_until
      and (p_school is null or r.school = p_school)
      and (p_campus is null or r.campus = p_campus)
  )
  select
    round(avg(wait_minutes)::numeric, 1),
    round((percentile_cont(0.5) within group (order by wait_minutes))::numeric, 1)
  into
    v_avg_wait,
    v_median_wait
  from matched_waits;

  -- 2. 活動成團與出席（不可將成團當成出席）
  select
    count(*),
    count(*) filter (where status = 'COMPLETED'),
    count(*) filter (where status = 'CANCELLED'),
    count(*) filter (where status in ('MATCHED', 'ONGOING'))
  into
    v_act_total,
    v_act_completed,
    v_act_cancelled,
    v_act_ongoing
  from activity
  where created_at >= p_since and created_at <= p_until
    and (p_school is null or school = p_school)
    and (p_campus is null or campus = p_campus);

  with member_evidence as (
    select
      am.activity_id,
      am.user_id,
      a.status as activity_status,
      (am.arrived_at is not null or exists (
        select 1 from user_reliability_event ure
        where ure.activity_id = am.activity_id and ure.user_id = am.user_id and ure.event_type = 'ATTENDED'
      )) as is_verified_attended,
      exists (
        select 1 from user_reliability_event ure
        where ure.activity_id = am.activity_id and ure.user_id = am.user_id and ure.event_type = 'NO_SHOW'
      ) as is_no_show
    from activity_member am
    join activity a on a.id = am.activity_id
    where a.created_at >= p_since and a.created_at <= p_until
      and (p_school is null or a.school = p_school)
      and (p_campus is null or a.campus = p_campus)
      and am.status = 'JOINED'
  )
  select
    count(*) filter (where is_verified_attended),
    count(*) filter (where activity_status = 'COMPLETED' and not is_verified_attended and not is_no_show),
    count(*) filter (where is_no_show)
  into
    v_verified_attended,
    v_unverified_completion,
    v_no_show
  from member_evidence;

  -- 3. 再次參與（真實活動參與留存 vs 需求重複發起留存）
  -- A. 實際活動參與留存
  with period_act_users as (
    select distinct am.user_id
    from activity_member am
    join activity a on a.id = am.activity_id
    where a.created_at >= p_since and a.created_at <= p_until
      and (p_school is null or a.school = p_school)
      and (p_campus is null or a.campus = p_campus)
      and am.status = 'JOINED'
  ),
  user_act_counts as (
    select
      pau.user_id,
      (
        select count(distinct am2.activity_id)
        from activity_member am2
        join activity a2 on a2.id = am2.activity_id
        where am2.user_id = pau.user_id
          and a2.created_at <= p_until
          and am2.status = 'JOINED'
      ) as total_activities_count
    from period_act_users pau
  )
  select
    count(*)::int,
    count(*) filter (where total_activities_count >= 2)::int,
    case
      when count(*) > 0 then round((count(*) filter (where total_activities_count >= 2)::numeric / count(*)::numeric), 3)
      else 0.000
    end
  into
    v_unique_act_users,
    v_repeat_act_users,
    v_repeat_act_rate
  from user_act_counts;

  -- B. 需求發起留存
  with period_req_users as (
    select distinct r.owner_id as user_id
    from match_request r
    where r.created_at >= p_since and r.created_at <= p_until
      and (p_school is null or r.school = p_school)
      and (p_campus is null or r.campus = p_campus)
  ),
  user_req_counts as (
    select
      pru.user_id,
      (
        select count(distinct mr.id)
        from match_request mr
        where mr.owner_id = pru.user_id
          and mr.created_at <= p_until
      ) as total_requests_count
    from period_req_users pru
  )
  select
    count(*)::int,
    count(*) filter (where total_requests_count >= 2)::int,
    case
      when count(*) > 0 then round((count(*) filter (where total_requests_count >= 2)::numeric / count(*)::numeric), 3)
      else 0.000
    end
  into
    v_unique_req_users,
    v_repeat_req_users,
    v_repeat_req_rate
  from user_req_counts;

  -- 4. 檢舉與人工審核
  select
    count(*),
    count(*) filter (where status = 'PENDING'),
    count(*) filter (where category = 'SPAM'),
    count(*) filter (where category = 'HARASSMENT'),
    count(*) filter (where category = 'OTHER')
  into
    v_total_reports,
    v_pending_reports,
    v_spam_reports,
    v_harass_reports,
    v_other_reports
  from report
  where created_at >= p_since and created_at <= p_until;

  select count(*) into v_feedbacks
  from feedback
  where created_at >= p_since and created_at <= p_until;

  return jsonb_build_object(
    'scope', jsonb_build_object(
      'school', p_school,
      'campus', p_campus,
      'since', p_since,
      'until', p_until
    ),
    'demand', jsonb_build_object(
      'total_requests', v_demand_total,
      'matched_requests', v_demand_matched,
      'expired_requests', v_demand_expired,
      'cancelled_requests', v_demand_cancelled,
      'avg_wait_to_match_minutes', v_avg_wait,
      'median_wait_to_match_minutes', v_median_wait,
      'cancelled_wait_minutes', 'UNKNOWN',
      'cancelled_reasons', 'UNKNOWN'
    ),
    'attendance', jsonb_build_object(
      'total_activities', v_act_total,
      'completed_activities', v_act_completed,
      'cancelled_activities', v_act_cancelled,
      'ongoing_or_matched_activities', v_act_ongoing,
      'verified_attended_members', v_verified_attended,
      'unverified_completion_members', v_unverified_completion,
      'no_show_members', v_no_show,
      'unverified_note', 'A4 timeout completion without arrival check-in or settlement is marked as UNKNOWN'
    ),
    'retention', jsonb_build_object(
      'unique_activity_participants', v_unique_act_users,
      'repeat_activity_participants', v_repeat_act_users,
      'repeat_activity_participation_rate', v_repeat_act_rate,
      'unique_request_users', v_unique_req_users,
      'repeat_request_users', v_repeat_req_users,
      'repeat_request_rate', v_repeat_req_rate
    ),
    'issues_and_workload', jsonb_build_object(
      'total_reports', v_total_reports,
      'pending_reports', v_pending_reports,
      'reports_by_category', jsonb_build_object(
        'SPAM', v_spam_reports,
        'HARASSMENT', v_harass_reports,
        'OTHER', v_other_reports
      ),
      'feedbacks_count', v_feedbacks,
      'notification_delivery_failures', 'PARTIALLY_UNKNOWN (only invalid push subscriptions 404/410 tracked via cleanup)',
      'weekly_maintenance_hours', 'UNKNOWN (manual log required)'
    )
  );
end;
$$;

revoke execute on function get_pilot_operational_metrics(school, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function get_pilot_operational_metrics(school, text, timestamptz, timestamptz) to service_role;
