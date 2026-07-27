-- =============================================================================
-- 帳號刪除（二）：所有身分驗證類 RPC 補上 ACCOUNT_DELETED 檢查（v1.14）
--
-- 22 支 RPC 全數 create or replace（保留原始簽章，確保真的取代而不是疊加成
-- overload）。檢查統一插在既有 UNAUTHORIZED（v_user_id is null）判斷之後、
-- 其餘業務檢查之前——submit_request/create_request 註解裡「定案的固定驗證
-- 序列」也同步改成 1.UNAUTHORIZED 2.ACCOUNT_DELETED 3.USER_SUSPENDED ...。
--
-- 完整清單與排除理由（見對話紀錄，不重複列在這裡）：
--   納入 22 支：complete_profile、get_my_reliability、propose_activity_type、
--   create_request、submit_request、cancel_request、get_or_create_invite_link、
--   join_request_by_token、revoke_invite_link、get_activity_contacts、
--   cancel_activity_participation、get_pending_confirmation_status、
--   respond_pending_confirmation、submit_completion_report、rematch_vote、
--   leave_request、propose_location、propose_activity_location、
--   vote_activity_location、update_meeting_point、update_meeting_hint、
--   respond_downgrade。
--   排除 2 支：search_activity_type（不使用 auth.uid()，純公開搜尋）、
--   fn_* 開頭的背景任務與內部 helper（commit_match/fn_run_matching_engine 等，
--   系統觸發，沒有呼叫者身分可言）。
--
-- complete_profile 特別說明：這支平常是新使用者的 onboarding 入口，此時
-- app_user 還沒有這筆 row，exists 查詢自然是 false，檢查不影響正常註冊流程；
-- 之所以仍然納入，是為了擋一個真實的殘留 JWT 風險——帳號刪除後、access token
-- 尚未自然過期的短暫視窗內，同一個 v_user_id 若重新呼叫 complete_profile，
-- on conflict (id) do update 會直接把已清空的識別欄位覆寫回真實資料，等同繞過
-- 整個刪除機制「復活」帳號。加了這個檢查後，已刪除帳號重新呼叫會被
-- ACCOUNT_DELETED 擋下，不會走到那段 upsert。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. complete_profile
-- -----------------------------------------------------------------------------
create or replace function complete_profile(
  p_display_name     text,
  p_avatar_url       text,
  p_degree_level     degree_level,
  p_department       text default null,
  p_gender           text default null,
  p_bio              text default null,
  p_contact_ig       text default null,
  p_contact_line     text default null,
  p_contact_discord  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_email    text;
  v_school   school;
  v_result   jsonb;
begin
  -- 驗證登入身分
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  -- 已刪除帳號不得靠重新呼叫 onboarding 入口復活（見檔頭說明）
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  -- 檢查停權狀態
  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  -- 驗證硬性門檻
  if p_display_name is null or trim(p_display_name) = '' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'DISPLAY_NAME_REQUIRED';
  end if;

  if p_avatar_url is null or trim(p_avatar_url) = '' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'AVATAR_URL_REQUIRED';
  end if;

  if p_degree_level is null then
    raise exception using message = 'DEGREE_LEVEL_REQUIRED';
  end if;

  if p_contact_ig is null and p_contact_line is null and p_contact_discord is null then
    raise exception using message = 'NO_CONTACT_METHOD', detail = 'AT_LEAST_ONE_CONTACT_REQUIRED';
  end if;

  -- 從 auth.users 取得 email 並推導學校（SPEC §2：不讓使用者自選）
  select email into v_email
    from auth.users
   where id = v_user_id;

  if v_email is null then
    raise exception using message = 'UNAUTHORIZED', detail = 'USER_EMAIL_NOT_FOUND';
  end if;

  if v_email ~* '@nycu\.edu\.tw$' then
    v_school := 'NYCU';
  elsif v_email ~* '@nthu\.edu\.tw$' then
    v_school := 'NTHU';
  else
    raise exception using message = 'INVALID_EMAIL_DOMAIN';
  end if;

  -- Upsert 到 app_user
  insert into app_user (
    id, email, school, display_name, avatar_url, degree_level,
    department, gender, bio, contact_ig, contact_line, contact_discord
  ) values (
    v_user_id, v_email, v_school, p_display_name, p_avatar_url, p_degree_level,
    p_department, p_gender, p_bio, p_contact_ig, p_contact_line, p_contact_discord
  )
  on conflict (id) do update set
    display_name    = excluded.display_name,
    avatar_url      = excluded.avatar_url,
    degree_level    = excluded.degree_level,
    department      = excluded.department,
    gender          = excluded.gender,
    bio             = excluded.bio,
    contact_ig      = excluded.contact_ig,
    contact_line    = excluded.contact_line,
    contact_discord = excluded.contact_discord;

  select to_jsonb(u.*) into v_result
    from app_user u
   where u.id = v_user_id;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. get_my_reliability
-- -----------------------------------------------------------------------------
create or replace function get_my_reliability()
returns jsonb
language plpgsql
stable
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

  return jsonb_build_object(
    'tier', fn_reliability_tier(v_user_id),
    'is_new_user', fn_is_new_user(v_user_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. propose_activity_type
-- -----------------------------------------------------------------------------
create or replace function propose_activity_type(p_name text)
returns activity_type
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_trimmed text := trim(p_name);
  v_result  activity_type;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  if v_trimmed is null or v_trimmed = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'NAME_REQUIRED';
  end if;

  -- 重複名稱檢查
  if exists (select 1 from activity_type where name = v_trimmed) then
    raise exception using message = 'DUPLICATE_TYPE_NAME';
  end if;

  insert into activity_type (name, status, created_by)
  values (v_trimmed, 'PENDING', v_user_id)
  returning * into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. create_request（驗證順序更新：1.UNAUTHORIZED 2.ACCOUNT_DELETED
--    3.PROFILE_INCOMPLETE 4.USER_SUSPENDED ...）
-- -----------------------------------------------------------------------------
create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus              text,
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

  select default_min_participants, default_max_participants, group_size_step
    into v_act_min, v_act_max, v_act_step
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
    raise exception using message = 'INVALID_INPUT', detail = 'INVALID_TIME_BUCKET';
  end if;

  if v_latest <= v_now then
    v_latest := v_now + interval '2 hours';
  end if;

  -- 5. 寫入 match_request
  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants,
    allow_downgrade, status
  ) values (
    v_user_id, p_activity_type_id, v_user_school, p_campus,
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
-- 5. submit_request（驗證順序更新：1.UNAUTHORIZED 2.ACCOUNT_DELETED
--    3.USER_SUSPENDED 4.PROFILE_INCOMPLETE ...）
-- -----------------------------------------------------------------------------
create or replace function submit_request(p_request_id uuid)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_user_school school;
  v_request     match_request;
  v_now         timestamptz := now();
  v_cooldown    timestamptz;
begin
  -- 1. UNAUTHORIZED
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  -- 2. ACCOUNT_DELETED
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  -- 3. USER_SUSPENDED
  if exists (select 1 from app_user where id = v_user_id and suspended_until > v_now) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  -- 4. PROFILE_INCOMPLETE (與 create_request 同一套判準：school 為 null 代表尚未完成 complete_profile)
  select school into v_user_school from app_user where id = v_user_id;
  if v_user_school is null then
    raise exception using message = 'PROFILE_INCOMPLETE';
  end if;

  -- 5. (結構性) NOT_FOUND / REQUEST_NOT_OPEN
  select * into v_request
    from match_request
   where id = p_request_id and owner_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status <> 'DRAFT' then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_NOT_IN_DRAFT_STATUS';
  end if;

  -- 6. ACTIVE_ACTIVITY_IN_PROGRESS (v1.7，SPEC §6.3：排在冷卻檢查之前，
  --    因為「活動還沒結束」是根源問題，跟「你剛退出了什麼」是不同階段)
  if exists (
    select 1 from activity_member am
    join activity a on a.id = am.activity_id
     where am.user_id = v_user_id
       and am.status = 'JOINED'
       and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS';
  end if;

  -- 7. REQUEST_COOLDOWN_ACTIVE (v1.7)
  select next_request_allowed_at into v_cooldown from app_user where id = v_user_id;
  if v_cooldown is not null and v_cooldown > v_now then
    raise exception using message = 'REQUEST_COOLDOWN_ACTIVE';
  end if;

  -- 8. 單一 REQUESTING 限制 (SPEC §6)
  if exists (select 1 from match_request where owner_id = v_user_id and status = 'REQUESTING') then
    raise exception using message = 'ALREADY_REQUESTING';
  end if;

  -- 9. 24h 時間窗限制 (SPEC §0)
  if v_request.latest_start > v_request.created_at + interval '24 hours' then
    raise exception using message = 'WINDOW_EXCEEDS_24H';
  end if;

  -- 10. 新人低人數門檻檢查 (SPEC §12.1)
  if v_request.min_participants <= 2 then
    if exists (
      select 1 from request_member rm
       where rm.request_id = p_request_id
         and rm.status = 'JOINED'
         and fn_is_new_user(rm.user_id) = true
    ) then
      raise exception using message = 'NEW_USER_LOW_HEADCOUNT';
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
-- 6. cancel_request
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
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_request
    from match_request
   where id = p_request_id and owner_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status not in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION') then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'CANNOT_CANCEL_FINISHED_REQUEST';
  end if;

  update match_request
     set status = 'CANCELLED'
   where id = p_request_id
  returning * into v_request;

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. get_or_create_invite_link
-- -----------------------------------------------------------------------------
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
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select invite_token into v_token
    from match_request
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
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

-- -----------------------------------------------------------------------------
-- 8. join_request_by_token
-- -----------------------------------------------------------------------------
create or replace function join_request_by_token(p_invite_token text)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_user_school   school;
  v_request       match_request;
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

  -- 查找對應的 Request
  select * into v_request
    from match_request
   where invite_token = p_invite_token
     and status = 'REQUESTING'
     and revoked_at is null
     for update;

  if not found then
    raise exception using message = 'INVITE_LINK_EXPIRED', detail = 'INVITE_LINK_EXPIRED_OR_REVOKED';
  end if;

  -- 同校隔離檢查 (v1.11：直接比對 match_request.school，不再需要 join location)
  if v_request.school <> v_user_school then
    raise exception using message = 'SCHOOL_LOCATION_MISMATCH';
  end if;

  -- 人數上限檢查
  select count(*) into v_current_count
    from request_member
   where request_id = v_request.id and status = 'JOINED';

  if v_request.max_participants is not null and v_current_count >= v_request.max_participants then
    raise exception using message = 'REQUEST_FULL';
  end if;

  -- 新人低人數門檻檢查
  if v_request.min_participants <= 2 and fn_is_new_user(v_user_id) = true then
    raise exception using message = 'NEW_USER_LOW_HEADCOUNT';
  end if;

  -- 新增或復原成員狀態
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'MEMBER', 'JOINED')
  on conflict (request_id, user_id) do update set status = 'JOINED';

  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. revoke_invite_link
-- -----------------------------------------------------------------------------
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
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  update match_request
     set revoked_at = now()
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  return true;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. get_activity_contacts
-- -----------------------------------------------------------------------------
create or replace function get_activity_contacts(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_activity    activity;
  v_is_visible  boolean := false;
  v_members     jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity
    from activity
   where id = p_activity_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  -- 檢查呼叫者是否為該活動成員
  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 判斷基礎時效：now() < contact_visible_until (+24h)
  v_is_visible := (now() < v_activity.contact_visible_until);

  -- 動態組裝成員清單與聯絡方式（聯絡資訊純留在 app_user，動態導出）
  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'display_name', u.display_name,
      'avatar_url', u.avatar_url,
      'role', am.status,
      -- 若 24h 未過期，或與對方有雙向 rematch_vote，才顯示聯絡方式 (SPEC §11)
      'contacts', case
        when v_is_visible or exists (
          select 1 from rematch_vote rv1
           join rematch_vote rv2 on rv1.activity_id = rv2.activity_id
          where rv1.activity_id = p_activity_id
            and rv1.from_user_id = v_user_id and rv1.to_user_id = u.id
            and rv2.from_user_id = u.id and rv2.to_user_id = v_user_id
        ) then jsonb_build_object(
          'contact_ig', u.contact_ig,
          'contact_line', u.contact_line,
          'contact_discord', u.contact_discord
        )
        else null
      end
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
 where am.activity_id = p_activity_id;

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'contact_visible_until', v_activity.contact_visible_until,
    'members', coalesce(v_members, '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. cancel_activity_participation
-- -----------------------------------------------------------------------------
create or replace function cancel_activity_participation(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_activity   activity;
  v_event_type reliability_event_type;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity
    from activity
   where id = p_activity_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 依時間點判定懲罰分級 (SPEC §10)：開始前 >= 1h 為 EARLY_CANCEL，否則為 LATE_CANCEL
  if now() < v_activity.start_time - interval '1 hour' then
    v_event_type := 'EARLY_CANCEL';
  else
    v_event_type := 'LATE_CANCEL';
  end if;

  -- 寫入 Reliability 事件
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_user_id, p_activity_id, v_event_type);

  -- LATE_CANCEL 觸發冷卻 (v1.7，SPEC §6.3；冷卻時長來自 app_config.cooldown_minutes)；EARLY_CANCEL 屬正常改行程，不觸發
  if v_event_type = 'LATE_CANCEL' then
    update app_user set next_request_allowed_at = now() + fn_get_config_interval('cooldown_minutes') where id = v_user_id;
  end if;

  -- 更新成員狀態
  update activity_member
     set status = 'CANCELLED'
   where activity_id = p_activity_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'event_type', v_event_type);
end;
$$;

-- -----------------------------------------------------------------------------
-- 12. get_pending_confirmation_status
-- -----------------------------------------------------------------------------
create or replace function get_pending_confirmation_status(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_pc      pending_confirmation;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_pc
    from pending_confirmation
   where (request_a_id = p_request_id or request_b_id = p_request_id)
   order by created_at desc
   limit 1;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  -- 嚴格落實對稱不歸因原則 (ERD 備註 16)：只回傳整體 status 與倒數時間，不透露個人 response 明細
  return jsonb_build_object(
    'pending_confirmation_id', v_pc.id,
    'status', v_pc.status,
    'confirm_window_expire_at', v_pc.confirm_window_expire_at
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 13. respond_pending_confirmation（最終版：呼叫 fn_create_activity_from_requests，
--     見 20260724122000_fix_commit_match_pc1.sql 的 PC1 重入 bug fix）
-- -----------------------------------------------------------------------------
create or replace function respond_pending_confirmation(
  p_pending_confirmation_id uuid,
  p_confirm                  boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_pc          pending_confirmation;
  v_is_user_a   boolean := false;
  v_new_resp    pending_confirmation_response;
  v_other_resp  pending_confirmation_response;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_pc
    from pending_confirmation
   where id = p_pending_confirmation_id
     for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  if v_pc.status <> 'PENDING' then
    raise exception using message = 'CONFIRMATION_WINDOW_CLOSED';
  end if;

  -- 判定呼叫者是 Party A 還是 Party B
  if exists (select 1 from match_request where id = v_pc.request_a_id and owner_id = v_user_id) then
    v_is_user_a := true;
    v_other_resp := v_pc.user_b_response;
  elsif exists (select 1 from match_request where id = v_pc.request_b_id and owner_id = v_user_id) then
    v_is_user_a := false;
    v_other_resp := v_pc.user_a_response;
  else
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_CONFIRMATION';
  end if;

  v_new_resp := case when p_confirm then 'CONFIRMED'::pending_confirmation_response else 'DECLINED'::pending_confirmation_response end;

  -- 原子性更新呼叫者自己的欄位
  if v_is_user_a then
    update pending_confirmation
       set user_a_response = v_new_resp
     where id = v_pc.id;
  else
    update pending_confirmation
       set user_b_response = v_new_resp
     where id = v_pc.id;
  end if;

  -- 原子性判定狀態轉移
  if p_confirm = false then
    -- 任一方拒絕 → 標記 DECLINED (清理作業由 Worker 或背景掃描執行)
    update pending_confirmation set status = 'DECLINED' where id = v_pc.id;

    -- 主動拒絕觸發冷卻 (v1.7，SPEC §6.3；冷卻時長來自 app_config.cooldown_minutes)；TIMEOUT 由背景 Worker 處理，不經過這裡，不觸發
    update app_user set next_request_allowed_at = now() + fn_get_config_interval('cooldown_minutes') where id = v_user_id;
  elsif v_other_resp = 'CONFIRMED' then
    -- 雙方皆同意 → 觸發 PC1，無條件建立 Activity（不經過 commit_match 的人數分支判斷）
    update pending_confirmation set status = 'CONFIRMED' where id = v_pc.id;
    perform fn_create_activity_from_requests(v_pc.request_a_id, v_pc.request_b_id);
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 14. submit_completion_report
-- -----------------------------------------------------------------------------
create or replace function submit_completion_report(
  p_activity_id     uuid,
  p_result          completion_result,
  p_absent_user_ids uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_total_members int;
  v_report_count  int;
  v_quorum        int;
  v_rec           record;
  v_no_show_cnt   int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 寫入回報 (DB UNIQUE (activity_id, reporter_id) 防重複)
  begin
    insert into completion_report (activity_id, reporter_id, result, absent_user_ids)
    values (p_activity_id, v_user_id, p_result, coalesce(p_absent_user_ids, '{}'));
  exception when unique_violation then
    raise exception using message = 'ALREADY_REPORTED';
  end;

  -- 計算成員總數與目前回報數
  select count(*) into v_total_members
    from activity_member
   where activity_id = p_activity_id and status = 'JOINED';

  select count(*) into v_report_count
    from completion_report
   where activity_id = p_activity_id;

  -- 多數決法定人數門檻 (>= 50% 參與者)
  v_quorum := ceil(v_total_members::numeric / 2.0);

  if v_report_count >= v_quorum then
    -- 結算處理：遍歷所有成員
    for v_rec in (
      select user_id from activity_member where activity_id = p_activity_id and status = 'JOINED'
    ) loop
      -- 統計指認該 member 缺席的次數
      select count(*) into v_no_show_cnt
        from completion_report cr, unnest(cr.absent_user_ids) uid
       where cr.activity_id = p_activity_id
         and uid = v_rec.user_id;

      -- 2 人互咬特例與多數決判定 (SPEC §10)
      if v_total_members = 2 and v_report_count = 2 and v_no_show_cnt = 1 then
        -- 2 人互相指認缺席 → 不判定 No-show，不記事件
        null;
      elsif v_no_show_cnt >= v_quorum then
        -- 被半數以上指認 → 記 NO_SHOW
        insert into user_reliability_event (user_id, activity_id, event_type)
        values (v_rec.user_id, p_activity_id, 'NO_SHOW');

        -- 連續 3 次 No-show 檢查 → 停權 7 天 (SPEC §12)
        if (
          select count(*)
            from (
              select event_type from user_reliability_event
               where user_id = v_rec.user_id
               order by created_at desc limit 3
            ) sub
           where sub.event_type = 'NO_SHOW'
        ) = 3 then
          update app_user set suspended_until = now() + interval '7 days' where id = v_rec.user_id;
        end if;
      else
        -- 正常出席 → 記 ATTENDED
        insert into user_reliability_event (user_id, activity_id, event_type)
        values (v_rec.user_id, p_activity_id, 'ATTENDED');
      end if;
    end loop;

    -- 更新 Activity 狀態為 COMPLETED
    update activity set status = 'COMPLETED' where id = p_activity_id;
  end if;

  return jsonb_build_object('success', true, 'settled', (v_report_count >= v_quorum));
end;
$$;

-- -----------------------------------------------------------------------------
-- 15. rematch_vote
-- -----------------------------------------------------------------------------
create or replace function rematch_vote(
  p_activity_id uuid,
  p_to_user_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id   uuid := auth.uid();
  v_is_mutual boolean := false;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if v_user_id = p_to_user_id then
    raise exception using message = 'INVALID_INPUT', detail = 'CANNOT_VOTE_SELF';
  end if;

  -- 檢查雙方是否皆為該活動成員
  if not exists (select 1 from activity_member where activity_id = p_activity_id and user_id = v_user_id) or
     not exists (select 1 from activity_member where activity_id = p_activity_id and user_id = p_to_user_id) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 寫入投票
  insert into rematch_vote (activity_id, from_user_id, to_user_id)
  values (p_activity_id, v_user_id, p_to_user_id)
  on conflict do nothing;

  -- 檢查是否雙向成立
  if exists (
    select 1 from rematch_vote
     where activity_id = p_activity_id and from_user_id = p_to_user_id and to_user_id = v_user_id
  ) then
    v_is_mutual := true;
  end if;

  return jsonb_build_object('success', true, 'is_mutual', v_is_mutual);
end;
$$;

-- -----------------------------------------------------------------------------
-- 16. leave_request
-- -----------------------------------------------------------------------------
create or replace function leave_request(p_request_id uuid)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_request match_request;
  v_member  request_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_request from match_request where id = p_request_id for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.owner_id = v_user_id then
    raise exception using message = 'FORBIDDEN', detail = 'OWNER_CANNOT_LEAVE_USE_CANCEL_REQUEST';
  end if;

  select * into v_member
    from request_member
   where request_id = p_request_id and user_id = v_user_id
     for update;

  if not found or v_member.status = 'LEFT' then
    raise exception using message = 'FORBIDDEN', detail = 'NOT_A_MEMBER_OF_REQUEST';
  end if;

  -- 配對成立前的邊界（同 cancel_request 的狀態檢查）：配對後改走 Activity 側的
  -- cancel_activity_participation（§6.3），兩張狀態圖的分界不容混用（API.md §9）
  if v_request.status not in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION') then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'CANNOT_LEAVE_FINISHED_REQUEST';
  end if;

  update request_member
     set status = 'LEFT'
   where request_id = p_request_id and user_id = v_user_id;

  -- 配對成立前退出不記 Reliability 事件（API.md §3.5 明文）
  return v_request;
end;
$$;

-- -----------------------------------------------------------------------------
-- 17. propose_location（campus 版本，v1.11 最終簽章）
-- -----------------------------------------------------------------------------
create or replace function propose_location(p_name text, p_school school, p_campus text)
returns location
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_trimmed      text := trim(p_name);
  v_trimmed_camp text := trim(p_campus);
  v_result       location;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  if v_trimmed is null or v_trimmed = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'NAME_REQUIRED';
  end if;

  if v_trimmed_camp is null or v_trimmed_camp = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'CAMPUS_REQUIRED';
  end if;

  if exists (select 1 from location where school = p_school and name = v_trimmed) then
    raise exception using message = 'DUPLICATE_LOCATION_NAME';
  end if;

  insert into location (school, name, campus, status, created_by, is_active)
  values (p_school, v_trimmed, v_trimmed_camp, 'PENDING', v_user_id, true)
  returning * into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 18. propose_activity_location
-- -----------------------------------------------------------------------------
create or replace function propose_activity_location(
  p_activity_id uuid,
  p_location_id uuid
)
returns activity_location_option
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_loc      location;
  v_result   activity_location_option;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 投票截止 = activity.start_time（由 fn_start_activities 鎖定），鎖定後或活動
  -- 已開始都不再接受新提案
  if v_activity.status <> 'MATCHED' or v_activity.activity_location_id is not null then
    raise exception using message = 'ACTIVITY_LOCATION_LOCKED';
  end if;

  select * into v_loc from location where id = p_location_id;
  if not found or v_loc.status <> 'APPROVED'
     or v_loc.school <> v_activity.school or v_loc.campus <> v_activity.campus then
    raise exception using message = 'INVALID_CAMPUS_SCOPE', detail = 'LOCATION_NOT_IN_ACTIVITY_SCOPE';
  end if;

  insert into activity_location_option (activity_id, location_id, proposed_by)
  values (p_activity_id, p_location_id, v_user_id)
  on conflict (activity_id, location_id) do nothing
  returning * into v_result;

  -- 該地點已是既有候選（他人提過）：提案動作退化成投票，不算錯誤
  if v_result.id is null then
    select * into v_result from activity_location_option
     where activity_id = p_activity_id and location_id = p_location_id;
  end if;

  insert into activity_location_vote (activity_id, user_id, location_id)
  values (p_activity_id, v_user_id, p_location_id)
  on conflict (activity_id, user_id) do update set location_id = excluded.location_id, voted_at = now();

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 19. vote_activity_location
-- -----------------------------------------------------------------------------
create or replace function vote_activity_location(
  p_activity_id uuid,
  p_location_id uuid
)
returns activity_location_vote
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_result   activity_location_vote;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  if v_activity.status <> 'MATCHED' or v_activity.activity_location_id is not null then
    raise exception using message = 'ACTIVITY_LOCATION_LOCKED';
  end if;

  if not exists (
    select 1 from activity_location_option
     where activity_id = p_activity_id and location_id = p_location_id
  ) then
    raise exception using message = 'NOT_FOUND', detail = 'LOCATION_OPTION_NOT_FOUND';
  end if;

  insert into activity_location_vote (activity_id, user_id, location_id)
  values (p_activity_id, v_user_id, p_location_id)
  on conflict (activity_id, user_id) do update set location_id = excluded.location_id, voted_at = now()
  returning * into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 20. update_meeting_point
-- -----------------------------------------------------------------------------
create or replace function update_meeting_point(
  p_activity_id uuid,
  p_description text
)
returns activity_meeting_point_update
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_desc     text := trim(p_description);
  v_result   activity_meeting_point_update;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if v_desc is null or v_desc = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'DESCRIPTION_REQUIRED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  -- 2 分鐘冷卻：直接查「該使用者對該活動最近一次更新是否在冷卻窗口內」，
  -- 不另開欄位存狀態（跟 known_member_count 同一個精神）。
  if exists (
    select 1 from activity_meeting_point_update
     where activity_id = p_activity_id
       and updated_by = v_user_id
       and created_at > now() - fn_get_config_interval('meeting_point_update_cooldown_minutes')
  ) then
    raise exception using message = 'MEETING_POINT_UPDATE_COOLDOWN';
  end if;

  insert into activity_meeting_point_update (activity_id, updated_by, description)
  values (p_activity_id, v_user_id, v_desc)
  returning * into v_result;

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MEETING_POINT_UPDATED',
         jsonb_build_object('activity_id', p_activity_id, 'description', v_desc, 'updated_by', v_user_id)
    from activity_member am
   where am.activity_id = p_activity_id and am.status = 'JOINED';

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 21. update_meeting_hint
-- -----------------------------------------------------------------------------
create or replace function update_meeting_hint(
  p_activity_id uuid,
  p_hint text
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_hint     text := nullif(trim(p_hint), '');
  v_result   activity_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if v_hint is not null and char_length(v_hint) > 30 then
    raise exception using message = 'INVALID_INPUT', detail = 'HINT_TOO_LONG';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  update activity_member
     set meeting_hint = v_hint
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  returning * into v_result;

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 22. respond_downgrade（最終版，含 DOWNGRADE_RESULT 通知，見
--     20260724122200_background_jobs_rpc.sql）
-- -----------------------------------------------------------------------------
create or replace function respond_downgrade(
  p_downgrade_request_id uuid,
  p_agree                 boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_dg         downgrade_request;
  v_consent    downgrade_consent;
  v_min        int;
  v_new_resp   downgrade_response;
  v_total      int;
  v_agreed     int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_dg from downgrade_request where id = p_downgrade_request_id for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'DOWNGRADE_REQUEST_NOT_FOUND';
  end if;

  -- 呼叫者必須是被詢問名單之一（downgrade_consent 的名單來源 = 建立時展開的
  -- request_member，見 init migration 的表註解）
  select * into v_consent
    from downgrade_consent
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_DOWNGRADE';
  end if;

  -- ERD 設計備註 21：target_size 必須低於原 min_participants，回應 RPC 也要應用層比對
  -- （不只建立時檢查一次），防止資料被非預期方式寫壞後還被回應 RPC 當合法狀態處理
  select min_participants into v_min from match_request where id = v_dg.request_id;
  if v_min is null or v_dg.target_size >= v_min then
    raise exception using message = 'INVALID_INPUT', detail = 'DOWNGRADE_TARGET_SIZE_NOT_BELOW_MIN_PARTICIPANTS';
  end if;

  -- 10 分鐘 CONSENT_WINDOW；超時 = 拒絕，Request 以原門檻回池（SPEC §8）——這裡只
  -- 擋「已經過期還想回應」，實際把 Request 留在原門檻是背景清理任務的職責（同
  -- fn_cleanup_pending_confirmations 的分工模式），不在本 RPC 內處理
  if v_dg.status <> 'PENDING' or v_dg.expire_at < now() then
    raise exception using message = 'CONSENT_WINDOW_CLOSED';
  end if;

  if v_consent.response <> 'NO_RESPONSE' then
    raise exception using message = 'ALREADY_RESPONDED';
  end if;

  v_new_resp := case when p_agree then 'AGREE'::downgrade_response else 'DISAGREE'::downgrade_response end;

  update downgrade_consent
     set response = v_new_resp, responded_at = now()
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id;

  if p_agree = false then
    -- 任一人 DISAGREE → 立即 REJECTED（STATE_MACHINE：「任一人 DISAGREE →
    -- downgrade_request → REJECTED，Request 以原 min/max_participants 留在池中」）
    update downgrade_request set status = 'REJECTED' where id = p_downgrade_request_id;

    insert into notification (user_id, event_type, payload)
    select dc.user_id, 'DOWNGRADE_RESULT',
           jsonb_build_object(
             'request_id', v_dg.request_id, 'downgrade_request_id', v_dg.id,
             'status', 'REJECTED', 'target_size', v_dg.target_size
           )
      from downgrade_consent dc
     where dc.downgrade_request_id = v_dg.id;
  else
    -- 全員 AGREE 才 APPROVED；重新以 target_size 撮合是 Matching Engine（§9）的
    -- 職責，本 RPC 只負責原子性的狀態轉移
    select count(*), count(*) filter (where response = 'AGREE')
      into v_total, v_agreed
      from downgrade_consent
     where downgrade_request_id = p_downgrade_request_id;

    if v_agreed = v_total then
      update downgrade_request set status = 'APPROVED' where id = p_downgrade_request_id;

      insert into notification (user_id, event_type, payload)
      select dc.user_id, 'DOWNGRADE_RESULT',
             jsonb_build_object(
               'request_id', v_dg.request_id, 'downgrade_request_id', v_dg.id,
               'status', 'APPROVED', 'target_size', v_dg.target_size
             )
        from downgrade_consent dc
       where dc.downgrade_request_id = v_dg.id;
    end if;
  end if;

  return jsonb_build_object('success', true);
end;
$$;
