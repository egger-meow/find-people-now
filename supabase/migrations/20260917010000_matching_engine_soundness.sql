-- =============================================================================
-- 配對引擎健壯性與邊界修復 (Matching Engine Soundness & Boundary Fixes) — v1.45
--
-- 重點修復：
-- 1. 全體參與者硬條件保證：
--    - 人數範圍：N 方累積時，累積總人數必須滿足所有參與者的 min_participants
--      與 max_participants（greatest(min) <= least(max)），不得只依種子需求。
--    - 活動等級：候選需求必須與目前累積集合中的「每一個」需求相容（防止傳遞性失效，
--      例如 A 等級 5 與 B 等級 4、C 等級 6 各自相容，但 B 與 C 距離為 2 不相容）。
--    - 讀書目標：候選需求必須與目前累積集合中的非空目標完全一致（防止 wildcard 種子
--      同時吸納「微積分」與「線性代數」兩種互斥科目）。
-- 2. 封鎖檢查全體成員覆蓋：
--    - 封鎖檢查下探至 request_member（status = 'JOINED'），若累積集合中任一成員
--      與候選需求中任一成員存在雙向 user_block 關係，即阻擋撮合。
-- 3. 延遲撮合與過期時間防護：
--    - 排除 latest_start <= now() 之過期需求。
--    - 共同時間窗交集必須滿足 greatest(v_new_earliest, now()) <= v_new_latest，
--      防止撮合出已在過去的開始時間，無有效未來交集絕不成團。
-- 4. 純邀請朋友自足成團支援：
--    - fn_create_activity_from_requests 支援 array_length >= 1。
--    - 當單筆 Request 透過邀請連結（join_request_by_token）已湊滿自身 min_participants
--      （例如 4 位朋友湊齊羽球局），引擎可直接為其建立 Activity 成團，不再被受限於
--      「必須至少 2 筆獨立 Request」而永久卡死在 REQUESTING。
-- 5. 並發與防重防呆：
--    - 候選需求若含有已在累積集合中的同一使用者，禁止合併，防止重複成團與主鍵衝突。
--    - fn_run_matching_engine 於 commit 時加入防禦性異常攔截，單一撮合並發競爭
--      不致導致整輪排程中斷。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. fn_create_activity_from_requests：支援單筆自足需求與人數檢查強化
-- -----------------------------------------------------------------------------
create or replace function fn_create_activity_from_requests(
  p_request_ids uuid[]
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity_type_id uuid;
  v_school           school;
  v_campus           text;
  v_start_time       timestamptz;
  v_latest_min       timestamptz;
  v_req_min          int;
  v_req_max          int;
  v_total_joined     int;
  v_dur              int;
  v_activity         activity;
  v_found_count      int;
  v_bad_status_count int;
begin
  if p_request_ids is null or array_length(p_request_ids, 1) < 1 then
    raise exception using message = 'INVALID_INPUT', detail = 'AT_LEAST_ONE_REQUEST_REQUIRED';
  end if;

  -- 鎖定全部涉及的 Request，原子處理
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

  -- 人數硬條件檢驗：實際成員數必須滿足全體要求
  select count(distinct rm.user_id) into v_total_joined
    from request_member rm
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED';

  if v_total_joined < v_req_min or (v_req_max is not null and v_total_joined > v_req_max) then
    raise exception using message = 'INTERNAL_ERROR', detail = 'HEADCOUNT_REQUIREMENTS_NOT_MET';
  end if;

  -- 開始時間推進至當前時間（若當前時間較晚）
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
-- 2. commit_match：補齊未來時間窗檢查
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

  -- 防禦性檢查：兩需求必須存在未來的有效共同時間交集
  if greatest(v_req_a.earliest_start, v_req_b.earliest_start, now()) > least(v_req_a.latest_start, v_req_b.latest_start) then
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  select count(distinct user_id) into v_total
    from request_member
   where request_id in (p_request_a_id, p_request_b_id) and status = 'JOINED';

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    return fn_create_activity_from_requests(array[p_request_a_id, p_request_b_id]);

  -- 分支 2：實際撮合人數 <= 2 → 建立 pending_confirmation (R3b)
  else
    insert into pending_confirmation (
      request_a_id, request_b_id, confirm_window_expire_at, status
    ) values (
      p_request_a_id, p_request_b_id, now() + fn_get_config_interval('confirm_window_minutes'), 'PENDING'
    );

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    return null;
  end if;
end;
$$;

revoke execute on function commit_match(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. fn_run_matching_engine：全體條件滿足、全體成員封鎖檢查、未來時段保護、自足團成團
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
             and r.id <> v_seed.id
           order by r.created_at asc
        ) loop
          exit when v_group_scans_used >= v_group_scan_budget;
          exit when v_accum_count >= v_accum_min_participants and array_length(v_accum_ids, 1) >= 2;

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
      if v_accum_count >= v_accum_min_participants
         and (v_accum_max_participants is null or v_accum_count <= v_accum_max_participants)
         and (array_length(v_accum_ids, 1) >= 2 or v_accum_count >= v_seed.min_participants)
      then
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
