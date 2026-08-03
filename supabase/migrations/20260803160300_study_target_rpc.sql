-- =============================================================================
-- 讀書「同伴目標」自由文字比對欄位 —— RPC / matching engine (v1.35)
-- =============================================================================
-- 1. create_request：新增 p_study_target 參數。只有 activity_type.name = '讀書'
--    時才有意義，否則一律把 study_target / study_target_normalized 都強制設為
--    null（靜默忽略，理由同 v1.34 的 skill_level_enabled=false 處理）。
--    其餘邏輯完全不變，照抄 20260803160100_skill_level_rpc.sql 的 create_request。
--
--    參數列表再次變動（新增 p_study_target），同樣須先 drop 掉上一版（8 參數，
--    含 p_skill_level）的簽章，理由同上一個 migration 的說明。
-- -----------------------------------------------------------------------------
drop function if exists create_request(uuid, text, timestamptz, timestamptz, int, int, boolean, skill_level);

create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus              text,
  p_earliest_start      timestamptz,
  p_latest_start        timestamptz,
  p_min_participants    int,
  p_max_participants    int default null,
  p_allow_downgrade     boolean default false,
  p_skill_level         skill_level default null,
  p_study_target        text default null
)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id                  uuid := auth.uid();
  v_user_school               school;
  v_act_min                   int;
  v_act_max                   int;
  v_act_step                  int;
  v_act_skill_enabled         boolean;
  v_act_name                  text;
  v_skill_level                skill_level;
  v_study_target                text;
  v_study_target_normalized     text;
  v_request                    match_request;
  v_now                         timestamptz := now();
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

  select default_min_participants, default_max_participants, group_size_step, skill_level_enabled, name
    into v_act_min, v_act_max, v_act_step, v_act_skill_enabled, v_act_name
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

  -- v1.35：study_target 只綁定「讀書」，否則一律存 null。原文與正規化分開算，
  -- 撮合比對只看 normalized 欄位，原文欄位純粹是給前端顯示用。
  if v_act_name = '讀書' then
    v_study_target := p_study_target;
    v_study_target_normalized := fn_normalize_study_target(p_study_target);
  else
    v_study_target := null;
    v_study_target_normalized := null;
  end if;

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
    allow_downgrade, status, skill_level, study_target, study_target_normalized
  ) values (
    v_user_id, p_activity_type_id, v_user_school, p_campus,
    p_earliest_start, p_latest_start, p_min_participants, p_max_participants,
    p_allow_downgrade, 'DRAFT', v_skill_level, v_study_target, v_study_target_normalized
  )
  returning * into v_request;

  -- 6. 新增 owner 為成員
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'OWNER', 'JOINED');

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. fn_run_matching_engine：在候選篩選 SQL 再加一個 study_target_normalized
--    相容性 AND 條件（null=wildcard，非 null 需完全相等，已在寫入時正規化過，
--    這裡直接比對即可，不用重複正規化）。其餘函式主體完全不變，照抄
--    20260803160100_skill_level_rpc.sql 的版本。
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
           -- ③study_target 相容性（v1.35，僅讀書類型會非 null）：null=wildcard，
           -- 非 null 需正規化後完全相同。比對用 *_normalized 欄位，不影響顯示用
           -- 的原文欄位。
           and (
             v_seed.study_target_normalized is null
             or r.study_target_normalized is null
             or v_seed.study_target_normalized = r.study_target_normalized
           )
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
-- 3. get_activity_member_profiles：新增回傳 study_target（原文，不是正規化後的
--    版本——前端顯示一律用使用者實際打的字，理由同本檔案開頭說明）。
--    其餘邏輯完全不變，照抄 20260803160100_skill_level_rpc.sql 的版本。
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
      'skill_level', mr.skill_level,
      'study_target', mr.study_target
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
  join match_request mr on mr.id = am.source_request_id
 where am.activity_id = p_activity_id;

  return coalesce(v_members, '[]'::jsonb);
end;
$$;
