-- =============================================================================
-- v1.16：修正 create_request 偏離 SPEC 原始意圖的實作 —— 時段桶換算邏輯
-- 移回前端，backend 只保留範圍合法性驗證
-- =============================================================================
-- SPEC.md §4 原文：「桶是 UI 層包裝，選完仍換算成具體 earliest_start/latest_start」。
-- 舊實作卻把 'NOW'/'TODAY'/'TONIGHT'/'TOMORROW_AM' 這組寫死的封閉集合直接放在
-- create_request 內部用 if/elsif 換算成時間戳，等於把「UI 要提供哪些桶選項」這個
-- 前端關注點焊死在 RPC 層——之後前端想改成 5 個桶（早上/中午/下午/傍晚/晚上）、
-- 動態顯示、或支援自由時間範圍模式，backend 都要跟著改，違反了 SPEC 原本「桶只是
-- UI 層包裝」的分工意圖。這不是新增功能，是把換算邏輯放回它該在的地方。
--
-- 新簽章：p_bucket text → p_earliest_start timestamptz, p_latest_start timestamptz
-- （前端算好、傳原始時間戳過來）。backend 保留的驗證：
--   1. p_latest_start <= p_earliest_start → INVALID_INPUT
--      detail LATEST_START_MUST_BE_AFTER_EARLIEST_START
--   2. p_latest_start > now() + 24h → WINDOW_EXCEEDS_24H（沿用既有錯誤碼）
--   3. p_latest_start < now() → INVALID_INPUT detail LATEST_START_IN_PAST
-- p_earliest_start 不做下限檢查：Matching Engine 本來就用 greatest(earliest_start, ...)
-- 決定實際 start_time，過早的 earliest_start 不影響正確性，前端夾好即可。
--
-- submit_request 既有的 `latest_start > created_at + 24h` 二次檢查維持不動：
-- 檢查時機不同（提交當下 vs 建立當下），但邏輯上恆為 false，不會誤傷，且不在本次
-- 修正範圍內。
-- =============================================================================

create or replace function create_request(
  p_activity_type_id    uuid,
  p_campus              text,
  p_earliest_start      timestamptz,
  p_latest_start        timestamptz,
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
    allow_downgrade, status
  ) values (
    v_user_id, p_activity_type_id, v_user_school, p_campus,
    p_earliest_start, p_latest_start, p_min_participants, p_max_participants,
    p_allow_downgrade, 'DRAFT'
  )
  returning * into v_request;

  -- 6. 新增 owner 為成員
  insert into request_member (request_id, user_id, role, status)
  values (v_request.id, v_user_id, 'OWNER', 'JOINED');

  return v_request;
end;
$$;
