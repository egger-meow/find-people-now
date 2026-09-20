-- =============================================================================
-- 競技運動人數步階保留、偶數優先撮合與防死鎖增強 (v1.45)
--
-- 1. Schema 簡化與步階設定：
--    - activity_type.default_min_participants 預設 2、default_max_participants 預設 20
--    - 競技/對抗型球類運動（籃球、羽球、網球、桌球）保留 group_size_step = 2，
--      防止使用者選到奇數人數（例如選 3 人）。
--    - 其餘活動（跑步、散步、讀書、健身、咖啡、唱K、練舞、桌遊、麻將）維持 null（連續整數）。
--
-- 2. 撮合引擎偶數優先（盡量湊成偶數，但不要絕對）：
--    - 對於競技類型活動（group_size_step = 2 或 level_system 屬於球類強度/等級），
--      當累積人數達到 min_participants 但為奇數時，引擎不提前退出，繼續掃描池中後續
--      候選需求以盡量湊成偶數。
--    - 「但不要絕對」：若池中候選掃描完畢仍為奇數（且滿足全員 min/max），仍正常成團，
--      絕不因堅持偶數而導致等待者永久卡在 REQUESTING（防止飢餓與死鎖）。
--
-- 3. 防死鎖保證 (Deadlock-Free Guarantees)：
--    - commit_match 鎖定順序固定為 order by id，杜絕並發交叉死鎖。
-- =============================================================================

-- 1. 設定 activity_type 欄位預設值與步階
alter table activity_type
  alter column default_min_participants set default 2,
  alter column default_max_participants set default 20;

update activity_type
   set default_min_participants = 2,
       default_max_participants = 20;

-- 競技與對抗型運動：step = 2（只允許偶數規模）
update activity_type
   set group_size_step = 2
 where name in ('籃球', '羽球', '網球', '桌球')
   and status = 'APPROVED';

-- 其餘活動：step = null（允許連續整數）
update activity_type
   set group_size_step = null
 where name not in ('籃球', '羽球', '網球', '桌球')
   and status = 'APPROVED';

-- 2. commit_match：保證依 id 排序鎖定，防止交叉死鎖
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
  -- 依照 id 嚴格排序鎖定，防止並發 (A, B) 與 (B, A) 交叉死鎖，且無多餘查詢負擔
  if p_request_a_id < p_request_b_id then
    select * into v_req_a from match_request where id = p_request_a_id for update;
    select * into v_req_b from match_request where id = p_request_b_id for update;
  else
    select * into v_req_b from match_request where id = p_request_b_id for update;
    select * into v_req_a from match_request where id = p_request_a_id for update;
  end if;

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

    -- 向雙方成員發送 PENDING_CONFIRMATION 通知（對稱不歸因，各帶收件者自己的 request_id）
    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_a_id)
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_b_id)
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    return null;
  end if;
end;
$$;

revoke execute on function commit_match(uuid, uuid) from public, anon, authenticated;

-- 3. fn_run_matching_engine：競技運動盡量湊成偶數（但不絕對），防止死鎖
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
  v_act_step               int;
  v_is_even_preferred      boolean;
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

    select level_system, group_size_step
      into v_act_level_system, v_act_step
      from activity_type
     where id = v_group.activity_type_id;

    -- 標註競技類型或指定 step=2 之活動：盡量湊成偶數
    v_is_even_preferred := (
      coalesce(v_act_step, 0) = 2
      or v_act_level_system in (
        'BASKETBALL_INTENSITY',
        'BADMINTON_LEVEL',
        'TENNIS_NTRP',
        'TABLE_TENNIS_SKILL'
      )
    );

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

          -- 檢查是否已達標退出：
          -- ① 若非偶數偏好，或人數已是偶數：達標即退出
          -- ② 若為競技/偶數偏好但當前人數為奇數：只要尚未達上限，繼續掃描以盡量湊成偶數；若已達上限則退出
          if v_accum_count >= v_accum_min_participants and array_length(v_accum_ids, 1) >= 2 then
            if not v_is_even_preferred or mod(v_accum_count, 2) = 0 then
              exit;
            end if;
            if v_accum_max_participants is not null and v_accum_count >= v_accum_max_participants then
              exit;
            end if;
          end if;

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
