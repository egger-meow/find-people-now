-- Keep the existing bounded scan for large queues. For a small scope, solve
-- the whole batch first: maximizing covered people prevents an early pair
-- from stranding other people who could have formed another group.
alter function public.fn_run_matching_engine() rename to fn_run_matching_engine_greedy;

create function public.fn_match_group_member_count(p_request_ids uuid[])
returns integer
language plpgsql stable set search_path = public as $$
declare
  v_n integer := coalesce(array_length(p_request_ids, 1), 0);
  v_request_count integer;
  v_member_count integer;
  v_unique_members integer;
  v_min integer;
  v_max integer;
  v_first_start timestamptz;
  v_last_start timestamptz;
  v_level_system level_system;
begin
  if v_n = 0 then return 0; end if;

  select count(*), max(min_participants),
         min(coalesce(max_participants, 2147483647)),
         max(earliest_start), min(latest_start)
    into v_request_count, v_min, v_max, v_first_start, v_last_start
    from match_request
   where id = any(p_request_ids)
     and status = 'REQUESTING';
  if v_request_count <> v_n or v_first_start is null
     or greatest(v_first_start, now()) > v_last_start then
    return 0;
  end if;
  if not exists (
    select 1 from match_request
     where id = any(p_request_ids)
       and (matching_ready_at is null or matching_ready_at <= now() - interval '30 seconds')
  ) then
    return 0;
  end if;

  select count(*), count(distinct user_id)
    into v_member_count, v_unique_members
    from request_member
   where request_id = any(p_request_ids) and status = 'JOINED';
  if v_member_count <> v_unique_members or v_member_count < v_min
     or v_member_count > v_max or (v_n = 1 and v_member_count <= 2) then
    return 0;
  end if;

  if exists (
    select 1 from request_member rm
    join activity_member am on am.user_id = rm.user_id and am.status = 'JOINED'
    join activity a on a.id = am.activity_id
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED'
     and a.status in ('MATCHED', 'ONGOING')
  ) then
    return 0;
  end if;

  if exists (
    select 1 from request_member left_rm
    join request_member right_rm on left_rm.user_id < right_rm.user_id
    join user_block ub on
      (ub.blocker_id = left_rm.user_id and ub.blocked_id = right_rm.user_id)
      or (ub.blocker_id = right_rm.user_id and ub.blocked_id = left_rm.user_id)
   where left_rm.request_id = any(p_request_ids) and left_rm.status = 'JOINED'
     and right_rm.request_id = any(p_request_ids) and right_rm.status = 'JOINED'
  ) then
    return 0;
  end if;

  select at.level_system into v_level_system
    from match_request r join activity_type at on at.id = r.activity_type_id
   where r.id = p_request_ids[1];
  if exists (
    select 1 from match_request left_r
    join match_request right_r on left_r.id < right_r.id
   where left_r.id = any(p_request_ids) and right_r.id = any(p_request_ids)
     and (
       not fn_sport_level_match(
         v_level_system, left_r.sport_level, right_r.sport_level)
       or (left_r.study_target_normalized is not null
           and right_r.study_target_normalized is not null
           and left_r.study_target_normalized <> right_r.study_target_normalized)
       or exists (
         select 1 from match_history_avoidance mha
          where mha.user_a_id = least(left_r.owner_id, right_r.owner_id)
            and mha.user_b_id = greatest(left_r.owner_id, right_r.owner_id)
            and mha.expire_at > now()
       )
     )
  ) then
    return 0;
  end if;

  return v_member_count;
end;
$$;

create function public.fn_match_bucket_exact(p_request_ids uuid[])
returns integer
language plpgsql set search_path = public as $$
declare
  v_n integer := coalesce(array_length(p_request_ids, 1), 0);
  v_full_mask integer;
  v_mask integer;
  v_group_mask integer;
  v_low_bit integer;
  v_score integer;
  v_best_score integer;
  v_group_count integer;
  v_best_group_count integer;
  v_group_ids uuid[];
  v_weight integer[];
  v_best integer[];
  v_groups integer[];
  v_choice integer[];
  v_match_count integer := 0;
begin
  if v_n = 0 or v_n > 12 then return 0; end if;
  v_full_mask := (1 << v_n) - 1;
  v_weight := array_fill(0, array[v_full_mask + 1]);
  v_best := array_fill(0, array[v_full_mask + 1]);
  v_groups := array_fill(0, array[v_full_mask + 1]);
  v_choice := array_fill(0, array[v_full_mask + 1]);

  -- A request is indivisible: invited friends stay with their owner.
  for v_group_mask in 1..v_full_mask loop
    select array_agg(p_request_ids[i] order by i) into v_group_ids
      from generate_series(1, v_n) i
     where (v_group_mask & (1 << (i - 1))) <> 0;
    v_weight[v_group_mask + 1] := fn_match_group_member_count(v_group_ids);
  end loop;

  -- Subset DP: each state either leaves its first request waiting or puts it
  -- in a viable group. The score is people matched, not groups formed or speed.
  for v_mask in 1..v_full_mask loop
    v_low_bit := v_mask & -v_mask;
    v_best_score := v_best[(v_mask # v_low_bit) + 1];
    v_best_group_count := v_groups[(v_mask # v_low_bit) + 1];
    for v_group_mask in 1..v_mask loop
      if v_weight[v_group_mask + 1] = 0
         or (v_group_mask & v_mask) <> v_group_mask
         or (v_group_mask & v_low_bit) = 0 then
        continue;
      end if;
      v_score := v_weight[v_group_mask + 1]
        + v_best[(v_mask # v_group_mask) + 1];
      v_group_count := 1 + v_groups[(v_mask # v_group_mask) + 1];
      if v_score > v_best_score
         or (v_score = v_best_score and v_group_count < v_best_group_count)
         or (v_score = v_best_score and v_group_count = v_best_group_count
             and v_choice[v_mask + 1] = 0) then
        v_best_score := v_score;
        v_best_group_count := v_group_count;
        v_choice[v_mask + 1] := v_group_mask;
      end if;
    end loop;
    v_best[v_mask + 1] := v_best_score;
    v_groups[v_mask + 1] := v_best_group_count;
  end loop;

  v_mask := v_full_mask;
  while v_mask > 0 loop
    v_group_mask := v_choice[v_mask + 1];
    if v_group_mask = 0 then
      v_mask := v_mask # (v_mask & -v_mask);
      continue;
    end if;
    select array_agg(p_request_ids[i] order by i) into v_group_ids
      from generate_series(1, v_n) i
     where (v_group_mask & (1 << (i - 1))) <> 0;
    begin
      if fn_match_group_member_count(v_group_ids) > 0 then
        if array_length(v_group_ids, 1) = 2
           and v_weight[v_group_mask + 1] = 2 then
          perform commit_match(v_group_ids[1], v_group_ids[2]);
        else
          perform fn_create_activity_from_requests(v_group_ids);
        end if;
        v_match_count := v_match_count + 1;
      end if;
    exception when others then
      -- A concurrent cancellation can invalidate a chosen group. The greedy
      -- pass below retries any still-requesting members on the next tick.
      null;
    end;
    v_mask := v_mask # v_group_mask;
  end loop;
  return v_match_count;
end;
$$;

create function public.fn_run_matching_engine()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_bucket record;
  v_match_count integer := 0;
begin
  if not pg_try_advisory_xact_lock(45001, 1) then return 0; end if;
  for v_bucket in
    select array_agg(id order by created_at, id) as request_ids
      from match_request
     where status = 'REQUESTING' and latest_start > now()
     group by activity_type_id, school, campus
    having count(*) between 1 and 12
  loop
    v_match_count := v_match_count
      + fn_match_bucket_exact(v_bucket.request_ids);
  end loop;
  return v_match_count + fn_run_matching_engine_greedy();
end;
$$;

revoke execute on function public.fn_match_group_member_count(uuid[])
  from public, anon, authenticated;
revoke execute on function public.fn_match_bucket_exact(uuid[])
  from public, anon, authenticated;
revoke execute on function public.fn_run_matching_engine()
  from public, anon, authenticated;
