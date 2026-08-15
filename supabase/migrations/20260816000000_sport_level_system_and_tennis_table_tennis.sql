-- =============================================================================
-- Sport-Specific Level System & Tennis / Table Tennis Support (v1.42)
-- =============================================================================
-- 1. 運動等級/強度體系重構：
--    既有的泛用 skill_level enum（BEGINNER/CASUAL/ADVANCED/COMPETITIVE）無法
--    準確表達不同運動的真實術語（籃球=強度、羽球=實力/級數、網球=NTRP、桌球=實力+選填積分）。
--    改為 per-activity_type 的 level_system 設定與 sport-aware 撮合比對規則。
--
-- 2. 新增官方運動類型：
--    - 網球 (Tennis)：NTRP 系統（2.0 以下至 5.0+，相差 <= 0.5 可相容配對）
--    - 桌球 (Table Tennis)：實力分級 + 選填積分，支援別名（乒乓球、Ping Pong、Table Tennis）
--
-- 3. 既有資料平滑移轉：
--    - match_request.sport_level (text) 與 sport_level_rating (int)
--    - 舊 match_request.skill_level 資料自動映射至對應運動的 sport_level 鍵值
-- =============================================================================

-- 1. 定義 level_system enum
create type level_system as enum (
  'NONE',
  'BASKETBALL_INTENSITY',
  'BADMINTON_LEVEL',
  'TENNIS_NTRP',
  'TABLE_TENNIS_SKILL'
);

-- 2. activity_type 欄位擴充
alter table activity_type
  add column if not exists level_system level_system not null default 'NONE',
  add column if not exists aliases text[] not null default '{}';

comment on column activity_type.level_system is
  '該活動類型所採用的等級/強度系統（NONE / BASKETBALL_INTENSITY / BADMINTON_LEVEL / TENNIS_NTRP / TABLE_TENNIS_SKILL）';

comment on column activity_type.aliases is
  '搜尋別名清單，如桌球包含 乒乓球, Ping Pong, Table Tennis';

-- 3. match_request 欄位擴充
alter table match_request
  add column if not exists sport_level text,
  add column if not exists sport_level_rating int;

comment on column match_request.sport_level is
  '運動 native 等級/強度值（如 EASY, REGULAR, LEVEL_1_5, NTRP_3_5, CASUAL_BEGINNER）；null = 不限 (wildcard)';

comment on column match_request.sport_level_rating is
  '選填運動積分（如桌球積分 1450）；僅作資訊呈現，不作為撮合硬性門檻';

-- 4. 既有資料遷移
-- 籃球：skill_level -> sport_level (EASY / REGULAR / HIGH / COMPETITIVE)
update match_request mr
   set sport_level = case mr.skill_level
     when 'BEGINNER' then 'EASY'
     when 'CASUAL' then 'REGULAR'
     when 'ADVANCED' then 'HIGH'
     when 'COMPETITIVE' then 'COMPETITIVE'
     else null
   end
  from activity_type act
 where act.id = mr.activity_type_id
   and act.name = '籃球'
   and mr.skill_level is not null;

-- 羽球：skill_level -> sport_level (LEVEL_1_5 / LEVEL_6_7 / LEVEL_8_10 / LEVEL_11_PLUS)
update match_request mr
   set sport_level = case mr.skill_level
     when 'BEGINNER' then 'LEVEL_1_5'
     when 'CASUAL' then 'LEVEL_6_7'
     when 'ADVANCED' then 'LEVEL_8_10'
     when 'COMPETITIVE' then 'LEVEL_11_PLUS'
     else null
   end
  from activity_type act
 where act.id = mr.activity_type_id
   and act.name = '羽球'
   and mr.skill_level is not null;

-- 5. 更新既有活動類型與寫入網球、桌球
update activity_type
   set level_system = 'BASKETBALL_INTENSITY',
       sort_order = 10
 where name = '籃球';

update activity_type
   set level_system = 'BADMINTON_LEVEL',
       sort_order = 10
 where name = '羽球';

-- 網球
insert into activity_type (
  name, status, default_duration_minutes, default_min_participants,
  default_max_participants, group_size_step, level_system, sort_order, description
) values (
  '網球', 'APPROVED', 120, 2, 8, null, 'TENNIS_NTRP', 10,
  '揪人打網球。NTRP 為自我評估等級，不確定可選不限。'
) on conflict (name) do update
  set status = 'APPROVED',
      default_duration_minutes = 120,
      default_min_participants = 2,
      default_max_participants = 8,
      group_size_step = null,
      level_system = 'TENNIS_NTRP',
      sort_order = 10,
      description = excluded.description;

-- 桌球
insert into activity_type (
  name, status, default_duration_minutes, default_min_participants,
  default_max_participants, group_size_step, level_system, sort_order, aliases, description
) values (
  '桌球', 'APPROVED', 90, 2, 8, null, 'TABLE_TENNIS_SKILL', 10,
  array['乒乓球', 'Ping Pong', 'Table Tennis'],
  '揪人打桌球。實力為自我評估等級，積分為選填。'
) on conflict (name) do update
  set status = 'APPROVED',
      default_duration_minutes = 90,
      default_min_participants = 2,
      default_max_participants = 8,
      group_size_step = null,
      level_system = 'TABLE_TENNIS_SKILL',
      sort_order = 10,
      aliases = array['乒乓球', 'Ping Pong', 'Table Tennis'],
      description = excluded.description;

-- 6. search_activity_type：支援別名模糊比對
create or replace function search_activity_type(p_query text)
returns setof activity_type
language sql
stable
security definer
set search_path = public
as $$
  select *
    from activity_type
   where status = 'APPROVED'
     and (
       p_query is null
       or trim(p_query) = ''
       or name ilike '%' || trim(p_query) || '%'
       or exists (
         select 1
           from unnest(aliases) alias_item
          where alias_item ilike '%' || trim(p_query) || '%'
       )
     )
   order by sort_order, name;
$$;

-- 7. fn_sport_level_match：sport-aware 撮合相容性判定函式
create or replace function fn_sport_level_match(
  p_system level_system,
  p_a text,
  p_b text
)
returns boolean
language plpgsql
immutable
as $$
declare
  v_a_num numeric;
  v_b_num numeric;
begin
  -- null = wildcard（不限 / 不確定，與任何等級皆相容）
  if p_a is null or p_b is null then
    return true;
  end if;

  if p_system = 'NONE' or p_system is null then
    return true;
  end if;

  -- 籃球強度：相鄰等級相容 (|a - b| <= 1)
  if p_system = 'BASKETBALL_INTENSITY' then
    v_a_num := case p_a
      when 'EASY' then 1
      when 'REGULAR' then 2
      when 'HIGH' then 3
      when 'COMPETITIVE' then 4
      else null
    end;
    v_b_num := case p_b
      when 'EASY' then 1
      when 'REGULAR' then 2
      when 'HIGH' then 3
      when 'COMPETITIVE' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  -- 羽球實力級數：相鄰級數區間相容 (|a - b| <= 1)
  if p_system = 'BADMINTON_LEVEL' then
    v_a_num := case p_a
      when 'LEVEL_1_5' then 1
      when 'LEVEL_6_7' then 2
      when 'LEVEL_8_10' then 3
      when 'LEVEL_11_PLUS' then 4
      else null
    end;
    v_b_num := case p_b
      when 'LEVEL_1_5' then 1
      when 'LEVEL_6_7' then 2
      when 'LEVEL_8_10' then 3
      when 'LEVEL_11_PLUS' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  -- 網球 NTRP：差值 <= 0.5 相容
  if p_system = 'TENNIS_NTRP' then
    v_a_num := case p_a
      when 'NTRP_2_0' then 2.0
      when 'NTRP_2_5' then 2.5
      when 'NTRP_3_0' then 3.0
      when 'NTRP_3_5' then 3.5
      when 'NTRP_4_0' then 4.0
      when 'NTRP_4_5' then 4.5
      when 'NTRP_5_0_PLUS' then 5.0
      when '2.0' then 2.0
      when '2.5' then 2.5
      when '3.0' then 3.0
      when '3.5' then 3.5
      when '4.0' then 4.0
      when '4.5' then 4.5
      when '5.0' then 5.0
      else null
    end;
    v_b_num := case p_b
      when 'NTRP_2_0' then 2.0
      when 'NTRP_2_5' then 2.5
      when 'NTRP_3_0' then 3.0
      when 'NTRP_3_5' then 3.5
      when 'NTRP_4_0' then 4.0
      when 'NTRP_4_5' then 4.5
      when 'NTRP_5_0_PLUS' then 5.0
      when '2.0' then 2.0
      when '2.5' then 2.5
      when '3.0' then 3.0
      when '3.5' then 3.5
      when '4.0' then 4.0
      when '4.5' then 4.5
      when '5.0' then 5.0
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 0.5;
  end if;

  -- 桌球實力：相鄰組別相容 (|a - b| <= 1)
  if p_system = 'TABLE_TENNIS_SKILL' then
    v_a_num := case p_a
      when 'CASUAL_BEGINNER' then 1
      when 'BASIC_SKILLS' then 2
      when 'REGULAR_PLAYER' then 3
      when 'VARSITY_TOURNAMENT' then 4
      else null
    end;
    v_b_num := case p_b
      when 'CASUAL_BEGINNER' then 1
      when 'BASIC_SKILLS' then 2
      when 'REGULAR_PLAYER' then 3
      when 'VARSITY_TOURNAMENT' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  return true;
end;
$$;

-- 8. create_request：更新參數簽章為 p_sport_level 與 p_sport_level_rating
drop function if exists create_request(uuid, text, timestamptz, timestamptz, int, int, boolean, skill_level, text);
drop function if exists create_request(uuid, text, timestamptz, timestamptz, int, int, boolean, text, int, text);

create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus              text,
  p_earliest_start      timestamptz,
  p_latest_start        timestamptz,
  p_min_participants    int,
  p_max_participants    int default null,
  p_allow_downgrade     boolean default false,
  p_sport_level         text default null,
  p_sport_level_rating  int default null,
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
  v_act_level_system          level_system;
  v_act_name                  text;
  v_sport_level               text;
  v_sport_level_rating        int;
  v_study_target              text;
  v_study_target_normalized   text;
  v_request                   match_request;
  v_now                       timestamptz := now();
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

  -- 2. Matching Scope 合法性檢查 (v1.11)
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

  select default_min_participants, default_max_participants, group_size_step, level_system, name
    into v_act_min, v_act_max, v_act_step, v_act_level_system, v_act_name
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

  -- 等級與選填積分：僅在該活動類型有啟用等級系統時儲存，否則一律存 null（靜默忽略）
  if v_act_level_system <> 'NONE' then
    v_sport_level := p_sport_level;
    v_sport_level_rating := p_sport_level_rating;
  else
    v_sport_level := null;
    v_sport_level_rating := null;
  end if;

  -- 讀書同伴目標：僅在「讀書」類型時儲存
  if v_act_name = '讀書' then
    v_study_target := p_study_target;
    v_study_target_normalized := fn_normalize_study_target(p_study_target);
  else
    v_study_target := null;
    v_study_target_normalized := null;
  end if;

  -- 4. 時間窗合法性驗證
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
    allow_downgrade, status, sport_level, sport_level_rating,
    study_target, study_target_normalized
  ) values (
    v_user_id, p_activity_type_id, v_user_school, p_campus,
    p_earliest_start, p_latest_start, p_min_participants, p_max_participants,
    p_allow_downgrade, 'DRAFT', v_sport_level, v_sport_level_rating,
    v_study_target, v_study_target_normalized
  )
  returning * into v_request;

  -- 6. 新增 owner 為成員
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'OWNER', 'JOINED');

  return v_request;
end;
$$;

-- 9. fn_run_matching_engine：升級為 sport-aware 等級比對
create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group               record;
  v_seed                match_request;
  v_has_prev_seed       boolean;
  v_prev_seed_created_at timestamptz;
  v_prev_seed_id        uuid;
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
  v_act_level_system    level_system;
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
         order by created_at asc, id asc
         limit 1;
      end if;

      exit seed_loop when v_seed.id is null;

      v_prev_seed_created_at := v_seed.created_at;
      v_prev_seed_id := v_seed.id;
      v_has_prev_seed := true;

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
           -- ① 人數區間重疊
           and (v_seed.max_participants is null or r.min_participants <= v_seed.max_participants)
           and (r.max_participants is null or v_seed.min_participants <= r.max_participants)
           -- ② sport-aware 等級相容性
           and fn_sport_level_match(v_act_level_system, v_seed.sport_level, r.sport_level)
           -- ③ 讀書目標相容性
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

-- 10. get_activity_member_profiles：回傳 sport_level, sport_level_rating, level_system
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
      'level_system', act.level_system,
      'sport_level', mr.sport_level,
      'sport_level_rating', mr.sport_level_rating,
      'study_target', mr.study_target
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
  join match_request mr on mr.id = am.source_request_id
  join activity_type act on act.id = mr.activity_type_id
 where am.activity_id = p_activity_id;

  return coalesce(v_members, '[]'::jsonb);
end;
$$;

-- 11. 權限設定 (GRANT EXECUTE)
grant execute on function create_request(uuid, text, timestamptz, timestamptz, int, int, boolean, text, int, text) to authenticated;
grant execute on function search_activity_type(text) to authenticated;
grant execute on function get_activity_member_profiles(uuid) to authenticated;
grant execute on function fn_is_request_member(uuid, uuid) to authenticated;
grant execute on function fn_is_activity_member(uuid, uuid) to authenticated;
