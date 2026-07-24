-- =============================================================================
-- Phase 3 RPCs — MatchRequest CRUD & Token Invitation
-- 派生自 docs/SPEC.md §4、§6、§7 及 docs/API.md §3
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: create_request
-- 建立 MatchRequest 草稿（僅成立 owner 本人為 request_member）
-- -----------------------------------------------------------------------------

create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus_location_id  uuid,
  p_bucket              text,
  p_min_participants    int,
  p_max_participants    int default null,
  p_allow_downgrade     boolean default false
)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id        uuid := auth.uid();
  v_user_school    school;
  v_loc_school     school;
  v_act_min        int;
  v_act_max        int;
  v_act_step       int;
  v_earliest       timestamptz;
  v_latest         timestamptz;
  v_request        match_request;
  v_now            timestamptz := now();
begin
  -- 1. 身分與停權檢查
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select school into v_user_school from app_user where id = v_user_id;
  if v_user_school is null then
    raise exception using errcode = 'PROFILE_INCOMPLETE', message = 'PROFILE_INCOMPLETE';
  end if;

  if exists (select 1 from app_user where id = v_user_id and suspended_until > v_now) then
    raise exception using errcode = 'USER_SUSPENDED', message = 'USER_SUSPENDED';
  end if;

  -- 2. 同校池隔離檢查 (SPEC §6/§7)
  select school into v_loc_school from location where id = p_campus_location_id and is_active = true;
  if v_loc_school is null or v_loc_school <> v_user_school then
    raise exception using errcode = 'SCHOOL_LOCATION_MISMATCH', message = 'SCHOOL_LOCATION_MISMATCH';
  end if;

  -- 3. 人數與離散步階檢查 (v1.5 / v1.6)
  if p_min_participants < 2 then
    raise exception using errcode = 'INVALID_MIN_PARTICIPANTS', message = 'MIN_PARTICIPANTS_MUST_BE_AT_LEAST_2';
  end if;

  if p_max_participants is not null and p_max_participants < p_min_participants then
    raise exception using errcode = 'INVALID_MAX_PARTICIPANTS', message = 'MAX_PARTICIPANTS_MUST_BE_GTE_MIN';
  end if;

  select default_min_participants, default_max_participants, group_size_step
    into v_act_min, v_act_max, v_act_step
    from activity_type
   where id = p_activity_type_id and status = 'APPROVED';

  if not found then
    raise exception using errcode = 'INVALID_INPUT', message = 'ACTIVITY_TYPE_NOT_FOUND_OR_NOT_APPROVED';
  end if;

  -- 離散步階驗證（group_size_step 非 null 時）
  if v_act_step is not null and v_act_step > 0 then
    if mod(p_min_participants - coalesce(v_act_min, 2), v_act_step) <> 0 then
      raise exception using errcode = 'INVALID_GROUP_SIZE_OPTION', message = 'INVALID_GROUP_SIZE_OPTION';
    end if;
    if p_max_participants is not null and mod(p_max_participants - coalesce(v_act_min, 2), v_act_step) <> 0 then
      raise exception using errcode = 'INVALID_GROUP_SIZE_OPTION', message = 'INVALID_GROUP_SIZE_OPTION';
    end if;
  end if;

  -- 4. 時間桶換算 (SPEC §4)
  if p_bucket = 'NOW' then
    v_earliest := v_now;
    v_latest   := v_now + interval '2 hours';
  elsif p_bucket = 'TODAY' then
    v_earliest := greatest(v_now, date_trunc('day', v_now) + interval '12 hours');
    v_latest   := date_trunc('day', v_now) + interval '23 hours';
  elsif p_bucket = 'TONIGHT' then
    v_earliest := greatest(v_now, date_trunc('day', v_now) + interval '18 hours');
    v_latest   := date_trunc('day', v_now) + interval '23 hours';
  elsif p_bucket = 'TOMORROW_AM' then
    v_earliest := date_trunc('day', v_now) + interval '1 day' + interval '8 hours';
    v_latest   := date_trunc('day', v_now) + interval '1 day' + interval '12 hours';
  else
    raise exception using errcode = 'INVALID_INPUT', message = 'INVALID_TIME_BUCKET';
  end if;

  if v_latest <= v_now then
    v_latest := v_now + interval '2 hours';
  end if;

  -- 5. 寫入 match_request
  insert into match_request (
    owner_id, activity_type_id, campus_location_id,
    earliest_start, latest_start, min_participants, max_participants,
    allow_downgrade, status
  ) values (
    v_user_id, p_activity_type_id, p_campus_location_id,
    v_earliest, v_latest, p_min_participants, p_max_participants,
    p_allow_downgrade, 'DRAFT'
  )
  returning * into v_request;

  -- 6. 新增 owner 為成員
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'OWNER', 'JOINED');

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: submit_request
-- 送出 Request 進 Queue（輕量驗證與狀態改變，不同步執行引擎）
-- -----------------------------------------------------------------------------

create or replace function submit_request(p_request_id uuid)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_request  match_request;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select * into v_request
    from match_request
   where id = p_request_id and owner_id = v_user_id
     for update;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status <> 'DRAFT' then
    raise exception using errcode = 'REQUEST_NOT_OPEN', message = 'REQUEST_NOT_IN_DRAFT_STATUS';
  end if;

  -- 單一 REQUESTING 限制 (SPEC §6)
  if exists (select 1 from match_request where owner_id = v_user_id and status = 'REQUESTING') then
    raise exception using errcode = 'ALREADY_REQUESTING', message = 'ALREADY_REQUESTING';
  end if;

  -- 24h 時間窗限制 (SPEC §0)
  if v_request.latest_start > v_request.created_at + interval '24 hours' then
    raise exception using errcode = 'WINDOW_EXCEEDS_24H', message = 'WINDOW_EXCEEDS_24H';
  end if;

  -- 新人低人數門檻檢查 (SPEC §12.1)
  if v_request.min_participants <= 2 then
    if exists (
      select 1 from request_member rm
       where rm.request_id = p_request_id
         and rm.status = 'JOINED'
         and fn_is_new_user(rm.user_id) = true
    ) then
      raise exception using errcode = 'NEW_USER_LOW_HEADCOUNT', message = 'NEW_USER_LOW_HEADCOUNT';
    end if;
  end if;

  update match_request
     set status = 'REQUESTING'
   where id = p_request_id
  returning * into v_request;

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. rpc: cancel_request
-- 配對前取消 Request (R5)
-- -----------------------------------------------------------------------------

create or replace function cancel_request(p_request_id uuid)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_request match_request;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select * into v_request
    from match_request
   where id = p_request_id and owner_id = v_user_id
     for update;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status not in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION') then
    raise exception using errcode = 'REQUEST_NOT_OPEN', message = 'CANNOT_CANCEL_FINISHED_REQUEST';
  end if;

  update match_request
     set status = 'CANCELLED'
   where id = p_request_id
  returning * into v_request;

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. 邀請連結相關 RPCs (v1.5)
-- -----------------------------------------------------------------------------

-- 4a. get_or_create_invite_link
create or replace function get_or_create_invite_link(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_token   text;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select invite_token into v_token
    from match_request
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'REQUEST_NOT_FOUND';
  end if;

  if v_token is null then
    v_token := encode(gen_random_bytes(12), 'hex');
    update match_request
       set invite_token = v_token
     where id = p_request_id;
  end if;

  return v_token;
end;
$$;

-- 4b. join_request_by_token (Trust Bootstrap)
create or replace function join_request_by_token(p_invite_token text)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_user_school   school;
  v_loc_school    school;
  v_request       match_request;
  v_current_count int;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  select school into v_user_school from app_user where id = v_user_id;
  if v_user_school is null then
    raise exception using errcode = 'PROFILE_INCOMPLETE', message = 'PROFILE_INCOMPLETE';
  end if;

  -- 查找對應的 Request
  select * into v_request
    from match_request
   where invite_token = p_invite_token
     and status = 'REQUESTING'
     and revoked_at is null
     for update;

  if not found then
    raise exception using errcode = 'INVITE_LINK_EXPIRED', message = 'INVITE_LINK_EXPIRED_OR_REVOKED';
  end if;

  -- 同校隔離檢查
  select school into v_loc_school from location where id = v_request.campus_location_id;
  if v_loc_school <> v_user_school then
    raise exception using errcode = 'SCHOOL_LOCATION_MISMATCH', message = 'SCHOOL_LOCATION_MISMATCH';
  end if;

  -- 人數上限檢查
  select count(*) into v_current_count
    from request_member
   where request_id = v_request.id and status = 'JOINED';

  if v_request.max_participants is not null and v_current_count >= v_request.max_participants then
    raise exception using errcode = 'REQUEST_FULL', message = 'REQUEST_FULL';
  end if;

  -- 新人低人數門檻檢查
  if v_request.min_participants <= 2 and fn_is_new_user(v_user_id) = true then
    raise exception using errcode = 'NEW_USER_LOW_HEADCOUNT', message = 'NEW_USER_LOW_HEADCOUNT';
  end if;

  -- 新增或復原成員狀態
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'MEMBER', 'JOINED')
  on conflict (request_id, user_id) do update set status = 'JOINED';

  return v_request;
end;
$$;

-- 4c. revoke_invite_link
create or replace function revoke_invite_link(p_request_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  update match_request
     set revoked_at = now()
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using errcode = 'NOT_FOUND', message = 'REQUEST_NOT_FOUND';
  end if;

  return true;
end;
$$;
