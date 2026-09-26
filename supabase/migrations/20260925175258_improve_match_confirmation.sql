-- Invited friends join the draft before the owner submits it for matching.
-- Matching starts after a short collection window counted from submission,
-- so a cron tick cannot strand the third person arriving seconds later.
alter table match_request add column matching_ready_at timestamptz;
create or replace function join_request_by_token(p_invite_token text)
returns match_request language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_user_school school;
  v_request match_request;
  v_current_count int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;
  select school into v_user_school from app_user where id = v_user_id;
  if v_user_school is null then
    raise exception using message = 'PROFILE_INCOMPLETE';
  end if;
  select * into v_request from match_request
    where invite_token = p_invite_token
      and status in ('DRAFT', 'REQUESTING')
      and revoked_at is null
      and latest_start > now()
    for update;
  if not found then
    raise exception using message = 'INVITE_LINK_EXPIRED', detail = 'INVITE_LINK_EXPIRED_OR_REVOKED';
  end if;
  if v_request.school <> v_user_school then
    raise exception using message = 'SCHOOL_LOCATION_MISMATCH';
  end if;
  if exists (select 1 from request_member
      where request_id = v_request.id and user_id = v_user_id and status = 'JOINED') then
    return v_request;
  end if;
  if exists (
    select 1 from request_member rm
    join match_request mr on mr.id = rm.request_id
    where rm.user_id = v_user_id and rm.status = 'JOINED'
      and mr.id <> v_request.id
      and mr.status in ('REQUESTING', 'PENDING_CONFIRMATION')
  ) then
    raise exception using message = 'ALREADY_REQUESTING';
  end if;
  if exists (
    select 1 from activity_member am
    join activity a on a.id = am.activity_id
    where am.user_id = v_user_id and am.status = 'JOINED'
      and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS';
  end if;
  select count(*) into v_current_count from request_member
    where request_id = v_request.id and status = 'JOINED';
  if v_request.max_participants is not null and v_current_count >= v_request.max_participants then
    raise exception using message = 'REQUEST_FULL';
  end if;
  if v_request.min_participants <= 2 and fn_is_new_user(v_user_id) then
    raise exception using message = 'NEW_USER_LOW_HEADCOUNT';
  end if;
  insert into request_member(request_id, user_id, role, status)
    values (v_request.id, v_user_id, 'MEMBER', 'JOINED')
    on conflict (request_id, user_id) do update set status = 'JOINED';
  return v_request;
end;
$$;

-- Report only the caller's own answer. The other party's answer remains private.
create or replace function get_pending_confirmation_status(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_pc pending_confirmation;
  v_own_response pending_confirmation_response;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;
  if not exists (
    select 1 from request_member
    where request_id = p_request_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'FORBIDDEN';
  end if;
  select * into v_pc from pending_confirmation
    where request_a_id = p_request_id or request_b_id = p_request_id
    order by created_at desc limit 1;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;
  v_own_response := case when v_pc.request_a_id = p_request_id
    then v_pc.user_a_response else v_pc.user_b_response end;
  return jsonb_build_object(
    'pending_confirmation_id', v_pc.id,
    'status', v_pc.status,
    'confirm_window_expire_at', v_pc.confirm_window_expire_at,
    'own_response', v_own_response
  );
end;
$$;

-- Maximize the number of compatible people in each activity before committing.
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
  v_remaining_count        int;
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

    select level_system
      into v_act_level_system
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
           and (matching_ready_at is null or matching_ready_at <= now() - interval '30 seconds')
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
           and (matching_ready_at is null or matching_ready_at <= now() - interval '30 seconds')
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

      -- 若種子本身尚未達到 max_participants（或無上限），嘗試併入候選需求
      if v_accum_max_participants is null or v_accum_count < v_accum_max_participants then
        for v_candidate in (
          select r.* from match_request r
           where r.activity_type_id = v_group.activity_type_id
             and r.school = v_group.school
             and r.campus = v_group.campus
             and r.status = 'REQUESTING'
             and r.latest_start > now()
             and (r.created_at, r.id) > (v_seed.created_at, v_seed.id)
           order by r.created_at asc, r.id asc
        ) loop
          exit when v_group_scans_used >= v_group_scan_budget;

          -- A full group cannot take another candidate; keep the scan bounded.
          exit when v_accum_max_participants is not null
            and v_accum_count >= v_accum_max_participants;

          -- Keep scanning compatible requests until the shared upper bound is reached.
          v_group_scans_used := v_group_scans_used + 1;

          -- 1. 即時狀態檢查（排除已非 REQUESTING 或已過期之候選）
          if not exists (
            select 1 from match_request
             where id = v_candidate.id
               and status = 'REQUESTING'
               and latest_start > now()
          ) then
            continue;
          end if;

          -- 2. 避免同一使用者重複進入活動（候選需求不得含有已在累積集合中的成員）
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

          -- 2b. 跨活動防重檢查（候選需求成員不得已在進行中/成立中的活動）
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

          -- 3. 雙向封鎖檢查（涵蓋所有成員，包括透過邀請連結加入的朋友）
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

          -- 4. 歷史冷卻檢查 (match_history_avoidance，比對 Request 發起人)
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

          -- 5. 時間窗重疊與未來可行性檢查（N 方交集且尚未過期）
          v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
          v_new_latest := least(v_accum_latest, v_candidate.latest_start);
          if greatest(v_new_earliest, now()) > v_new_latest then
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

          -- 7. 讀書目標相容性（與累積集合中每一個需求皆須相容，防止互斥科目被撮合）
          if exists (
            select 1
              from match_request mr_acc
             where mr_acc.id = any(v_accum_ids)
               and mr_acc.study_target_normalized is not null
               and v_candidate.study_target_normalized is not null
               and mr_acc.study_target_normalized <> v_candidate.study_target_normalized
          ) then
            continue;
          end if;

          -- 8. 人數上下限相容性（全體累積人數必須符合每位參與者的上下限）
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

          -- If adding this person would strand a too-small remainder, keep
          -- the current viable group and leave this candidate for the next one.
          -- This makes 4 people with a maximum of 3 form 2+2, while 3 form 3.
          if v_accum_count >= v_accum_min_participants
             and v_new_max_participants is not null then
            select count(distinct rm.user_id) into v_remaining_count
              from match_request r
              join request_member rm on rm.request_id = r.id and rm.status = 'JOINED'
             where r.activity_type_id = v_group.activity_type_id
               and r.school = v_group.school
               and r.campus = v_group.campus
               and r.status = 'REQUESTING'
               and r.latest_start > now()
               and r.id <> all(v_accum_ids)
               and r.id <> v_candidate.id;
            if v_remaining_count > 0
               and v_remaining_count < v_new_min_participants
               and v_accum_count + v_cand_count + v_remaining_count > v_new_max_participants then
              continue;
            end if;
          end if;

          -- 相容，加入累積集合
          v_accum_ids := v_accum_ids || v_candidate.id;
          v_accum_count := v_accum_count + v_cand_count;
          v_accum_earliest := v_new_earliest;
          v_accum_latest := v_new_latest;
          v_accum_min_participants := v_new_min_participants;
          v_accum_max_participants := v_new_max_participants;
        end loop;
      end if;

      -- 成團判定：
      -- ① 實際總人數必須達到所有人的 min_participants 上限，且不超過任一人的 max_participants
      -- ② 若為單筆 Request，其成員數必須已自行達到 min_participants（純邀請朋友湊滿達標）
      -- ③ 若為多筆 Request 聚合，總成員數必須達標且組數 >= 2
      -- ④ 「但不要絕對」：不論最後人數是偶數還是奇數，只要滿足全員條件皆可成團，不造成死鎖！
      if v_accum_count >= v_accum_min_participants
         and (v_accum_max_participants is null or v_accum_count <= v_accum_max_participants)
         and (array_length(v_accum_ids, 1) >= 2 or (array_length(v_accum_ids, 1) = 1 and v_accum_count > 2 and v_accum_count >= v_seed.min_participants))
      then
        -- 單房自足成團與多房撮合成團之跨活動防重保險：累積名單中任一成員不得已在活動中
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
            -- 遇並發衝突（如候選剛好被取消或進入其他活動），略過該次嘗試，引擎繼續掃描
            null;
          end;
      end if;

    end loop seed_loop;
  end loop group_loop;

  return v_match_count;
end;
$$;

revoke execute on function fn_run_matching_engine() from public, anon, authenticated;
