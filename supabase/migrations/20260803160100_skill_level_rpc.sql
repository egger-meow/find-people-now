-- =============================================================================
-- Skill Level（競技類型技能程度）—— RPC / matching engine (v1.34)
-- =============================================================================
-- 1. fn_skill_level_match：把「兩個 skill_level 是否相容」抽成獨立函式，不直接
--    寫進 fn_run_matching_engine 的候選篩選 SQL。這輪邏輯只有「null=wildcard、
--    非 null 需相等」，抽出來是為了未來若要放寬成非對稱規則（例如「競技」可以
--    配「進階」）時，只改這支函式，不用回頭動已經很密集的候選篩選查詢。
-- -----------------------------------------------------------------------------
create or replace function fn_skill_level_match(p_a skill_level, p_b skill_level)
returns boolean
language sql
immutable
as $$
  select p_a is null or p_b is null or p_a = p_b;
$$;

-- -----------------------------------------------------------------------------
-- 2. create_request：新增 p_skill_level 參數。若該 activity_type 的
--    skill_level_enabled = false，一律把要寫入的值強制設為 null（靜默忽略，
--    不報錯）——DB 層是最終防線，即使有人繞過前端直接呼叫 RPC 也不會寫入
--    不該存在的值；也不需要為此新增一個錯誤碼。
--    其餘邏輯完全不變，照抄 20260724124000_create_request_earliest_latest.sql。
--
--    參數列表變動（新增 p_skill_level），`create or replace` 對不同簽章會
--    疊加成第二個 overload 而不是取代舊的，必須先 drop 掉舊簽章（比照
--    20260803150000_bio_avatar_hard_requirements.sql 檔頭註解說明的規則）。
-- -----------------------------------------------------------------------------
drop function if exists create_request(uuid, text, timestamptz, timestamptz, int, int, boolean);

create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus              text,
  p_earliest_start      timestamptz,
  p_latest_start        timestamptz,
  p_min_participants    int,
  p_max_participants    int default null,
  p_allow_downgrade     boolean default false,
  p_skill_level         skill_level default null
)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id             uuid := auth.uid();
  v_user_school         school;
  v_act_min             int;
  v_act_max             int;
  v_act_step            int;
  v_act_skill_enabled   boolean;
  v_skill_level         skill_level;
  v_request             match_request;
  v_now                 timestamptz := now();
begin
  -- 1. 身分與停權檢查
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

  if exists (select 1 from app_user where id = v_user_id and suspended_until > v_now) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  -- 2. Matching Scope 合法性檢查 (v1.11)：campus 必須屬於 owner 的 school 底下
  --    至少一筆已核准的地點，否則這個 campus 範圍在該校根本不存在任何候選地點
  if not exists (
    select 1 from location
     where school = v_user_school and campus = p_campus and status = 'APPROVED'
  ) then
    raise exception using message = 'INVALID_CAMPUS_SCOPE', detail = 'NO_APPROVED_LOCATION_IN_CAMPUS';
  end if;

  -- 3. 人數與離散步階檢查 (v1.5 / v1.6)
  if p_min_participants < 2 then
    raise exception using message = 'INVALID_MIN_PARTICIPANTS', detail = 'MIN_PARTICIPANTS_MUST_BE_AT_LEAST_2';
  end if;

  if p_max_participants is not null and p_max_participants < p_min_participants then
    raise exception using message = 'INVALID_MAX_PARTICIPANTS', detail = 'MAX_PARTICIPANTS_MUST_BE_GTE_MIN';
  end if;

  select default_min_participants, default_max_participants, group_size_step, skill_level_enabled
    into v_act_min, v_act_max, v_act_step, v_act_skill_enabled
    from activity_type
   where id = p_activity_type_id and status = 'APPROVED';

  if not found then
    raise exception using message = 'INVALID_INPUT', detail = 'ACTIVITY_TYPE_NOT_FOUND_OR_NOT_APPROVED';
  end if;

  -- 離散步階驗證（group_size_step 非 null 時）
  if v_act_step is not null and v_act_step > 0 then
    if mod(p_min_participants - coalesce(v_act_min, 2), v_act_step) <> 0 then
      raise exception using message = 'INVALID_GROUP_SIZE_OPTION';
    end if;
    if p_max_participants is not null and mod(p_max_participants - coalesce(v_act_min, 2), v_act_step) <> 0 then
      raise exception using message = 'INVALID_GROUP_SIZE_OPTION';
    end if;
  end if;

  -- v1.34：skill_level 只在該 activity_type 開啟時才有意義，否則一律存 null。
  v_skill_level := case when v_act_skill_enabled then p_skill_level else null end;

  -- 4. 時間窗合法性驗證（v1.16：桶換算移回前端，這裡只驗證範圍）
  if p_latest_start <= p_earliest_start then
    raise exception using message = 'INVALID_INPUT', detail = 'LATEST_START_MUST_BE_AFTER_EARLIEST_START';
  end if;

  if p_latest_start > v_now + interval '24 hours' then
    raise exception using message = 'WINDOW_EXCEEDS_24H';
  end if;

  if p_latest_start < v_now then
    raise exception using message = 'INVALID_INPUT', detail = 'LATEST_START_IN_PAST';
  end if;

  -- 5. 寫入 match_request
  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    allow_downgrade, status, skill_level
  ) values (
    v_user_id, p_activity_type_id, v_user_school, p_campus,
    p_earliest_start, p_latest_start, p_min_participants, p_max_participants,
    p_allow_downgrade, 'DRAFT', v_skill_level
  )
  returning * into v_request;

  -- 6. 新增 owner 為成員
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'OWNER', 'JOINED');

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. fn_run_matching_engine：在 v1.15 N 方累積演算法既有的候選篩選 SQL
--    （人數區間重疊那段）新增一個 skill_level 相容性 AND 條件，呼叫
--    fn_skill_level_match，不獨立寫平行邏輯。其餘函式主體完全不變，照抄
--    20260724125400_matching_engine_advisory_lock.sql。
-- -----------------------------------------------------------------------------
create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group              record;
  v_seed                match_request;
  v_tried_seed_ids      uuid[];
  v_candidate           record;
  v_accum_ids           uuid[];
  v_accum_owner_ids     uuid[];
  v_accum_count         int;
  v_accum_earliest      timestamptz;
  v_accum_latest        timestamptz;
  v_new_earliest        timestamptz;
  v_new_latest          timestamptz;
  v_cand_count          int;
  v_match_count         int := 0;
  v_group_scan_budget   constant int := 5000;
  v_group_scans_used    int;
begin
  if not pg_try_advisory_xact_lock(45001, 1) then
    return 0;
  end if;

  <<group_loop>>
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    v_tried_seed_ids := array[]::uuid[];
    v_group_scans_used := 0;

    <<seed_loop>>
    loop
      select * into v_seed
        from match_request
       where activity_type_id = v_group.activity_type_id
         and school = v_group.school
         and campus = v_group.campus
         and status = 'REQUESTING'
         and not (id = any(v_tried_seed_ids))
       order by created_at asc
       limit 1;

      exit seed_loop when v_seed.id is null;

      v_tried_seed_ids := v_tried_seed_ids || v_seed.id;

      select count(*) into v_accum_count
        from request_member where request_id = v_seed.id and status = 'JOINED';

      v_accum_ids := array[v_seed.id];
      v_accum_owner_ids := array[v_seed.owner_id];
      v_accum_earliest := v_seed.earliest_start;
      v_accum_latest := v_seed.latest_start;

      for v_candidate in (
        select r.* from match_request r
         where r.activity_type_id = v_group.activity_type_id
           and r.school = v_group.school
           and r.campus = v_group.campus
           and r.status = 'REQUESTING'
           and r.id <> v_seed.id
           -- ①候選篩選：[候選 min,max] 跟 [種子 min,max] 存在至少一個雙方都能接受的
           -- 人數（null = 不設上限，視為 +∞）。殘留邊界情況見 20260724123000 檔頭說明。
           and (v_seed.max_participants is null or r.min_participants <= v_seed.max_participants)
           and (r.max_participants is null or v_seed.min_participants <= r.max_participants)
           -- ②skill_level 相容性（v1.34）：null=wildcard，非 null 只跟相同等級或
           -- 對方是 null 相容，邏輯封裝在 fn_skill_level_match。
           and fn_skill_level_match(v_seed.skill_level, r.skill_level)
         order by r.created_at asc
      ) loop
        exit when v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2;

        v_group_scans_used := v_group_scans_used + 1;

        if not exists (select 1 from match_request where id = v_candidate.id and status = 'REQUESTING') then
          continue;
        end if;

        v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
        v_new_latest := least(v_accum_latest, v_candidate.latest_start);
        if v_new_earliest > v_new_latest then
          continue;
        end if;

        if exists (
          select 1
            from unnest(v_accum_owner_ids) as ao(owner_id)
            join match_history_avoidance mha
              on mha.user_a_id = least(ao.owner_id, v_candidate.owner_id)
             and mha.user_b_id = greatest(ao.owner_id, v_candidate.owner_id)
             and mha.expire_at > now()
        ) then
          continue;
        end if;

        if exists (
          select 1
            from unnest(v_accum_owner_ids) as ao(owner_id)
            join user_block ub
              on (ub.blocker_id = ao.owner_id and ub.blocked_id = v_candidate.owner_id)
              or (ub.blocker_id = v_candidate.owner_id and ub.blocked_id = ao.owner_id)
        ) then
          continue;
        end if;

        select count(*) into v_cand_count
          from request_member where request_id = v_candidate.id and status = 'JOINED';

        if v_seed.max_participants is not null and v_accum_count + v_cand_count > v_seed.max_participants then
          continue;
        end if;

        v_accum_ids := v_accum_ids || v_candidate.id;
        v_accum_owner_ids := v_accum_owner_ids || v_candidate.owner_id;
        v_accum_count := v_accum_count + v_cand_count;
        v_accum_earliest := v_new_earliest;
        v_accum_latest := v_new_latest;
      end loop;

      if v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2 then
        if v_accum_count > 2 then
          perform fn_create_activity_from_requests(v_accum_ids);
        else
          perform commit_match(v_accum_ids[1], v_accum_ids[2]);
        end if;
        v_match_count := v_match_count + 1;
      end if;

      exit seed_loop when v_group_scans_used >= v_group_scan_budget;
    end loop;
  end loop;

  return v_match_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. get_activity_member_profiles：新增回傳 skill_level（撮合成立後的成員名單
--    顯示用）。透過 activity_member.source_request_id join 回原始 match_request
--    ——這筆 Request 撮合成立後仍會保留（status 改為 MATCHED，不會被刪除），
--    不需要把 skill_level 另外複製一份到 activity_member。
--    其餘邏輯完全不變，照抄 20260803150100_activity_member_profiles_bio.sql。
-- -----------------------------------------------------------------------------
create or replace function get_activity_member_profiles(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_members jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if not exists (select 1 from activity where id = p_activity_id) then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'school', u.school,
      'department', u.department,
      'degree_level', u.degree_level,
      'bio', u.bio,
      'reliability_tier', fn_reliability_tier(u.id),
      'skill_level', mr.skill_level
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
  join match_request mr on mr.id = am.source_request_id
 where am.activity_id = p_activity_id;

  return coalesce(v_members, '[]'::jsonb);
end;
$$;
