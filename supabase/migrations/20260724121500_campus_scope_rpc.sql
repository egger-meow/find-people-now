-- =============================================================================
-- Matching Engine 空間維度重構：RPC 改寫（v1.11）
-- 派生自使用者需求：campus_location_id 精確地點匹配 → (school, campus) 範圍匹配
-- 依附 20260724121400_campus_scope_schema.sql 的 schema 變更
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. create_request：p_campus_location_id → p_campus text
--    地點合法性檢查從「FK 存在 + school 相符」改成「campus 字串存在性檢查」
-- -----------------------------------------------------------------------------
-- 新錯誤碼 INVALID_CAMPUS_SCOPE：語意是「學校正確，但該校區無可用地點」，
-- 跟舊的 SCHOOL_LOCATION_MISMATCH（學校本身不對）刻意分開，不沿用舊碼。
-- campus 打字錯誤風險不加額外 DB 層約束（UNIQUE / lookup 表）：這道存在性檢查
-- 已經能擋掉使用者端輸入錯誤，唯一剩餘風險是 admin 手動維護地點清單時自己打字
-- 不一致，屬於操作紀律問題，不是 schema 該解的問題。

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
-- 2. join_request_by_token：同校檢查簡化為直接比對 match_request.school，
--    不再需要 join location（match_request 現在自己就帶 school）
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
-- 3. commit_match：Activity 建立時複製 school/campus（取代 campus_location_id），
--    activity_location_id 留 NULL，等投票鎖定
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
  v_req_a      match_request;
  v_req_b      match_request;
  v_count_a    int;
  v_count_b    int;
  v_total      int;
  v_activity   activity;
  v_dur        int;
  v_start_time timestamptz;
begin
  -- 鎖定雙方 Request 進行原子處理
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_count_a from request_member where request_id = p_request_a_id and status = 'JOINED';
  select count(*) into v_count_b from request_member where request_id = p_request_b_id and status = 'JOINED';
  v_total := v_count_a + v_count_b;

  -- 取得活動類型的預設時長（fallback 60m）
  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_req_a.activity_type_id;

  v_start_time := greatest(v_req_a.earliest_start, v_req_b.earliest_start);

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    insert into activity (
      activity_type_id, school, campus, start_time, estimated_end_time,
      status, contact_visible_until
    ) values (
      v_req_a.activity_type_id, v_req_a.school, v_req_a.campus,
      v_start_time, v_start_time + (v_dur || ' minutes')::interval,
      'MATCHED', now() + interval '24 hours'
    )
    returning * into v_activity;

    -- 寫入 activity_member
    insert into activity_member (activity_id, user_id, source_request_id, status)
    select v_activity.id, rm.user_id, p_request_a_id, 'JOINED'
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into activity_member (activity_id, user_id, source_request_id, status)
    select v_activity.id, rm.user_id, p_request_b_id, 'JOINED'
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    -- 更新 Request 狀態
    update match_request set status = 'MATCHED' where id in (p_request_a_id, p_request_b_id);

    -- 發送通知
    insert into notification (user_id, event_type, payload)
    select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
      from activity_member am where am.activity_id = v_activity.id;

    return v_activity;

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

-- -----------------------------------------------------------------------------
-- 4. fn_run_matching_engine：merge 條件從單一 campus_location_id 改成
--    (school, campus) 兩欄位比對
-- -----------------------------------------------------------------------------

create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec        record;
  v_req_a      record;
  v_req_b      record;
  v_match_count int := 0;
begin
  -- 遍歷所有有 REQUESTING 狀態 Request 的 (activity_type, school, campus) 組合
  for v_rec in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    -- 尋找可撮合的 Request 對
    for v_req_a in (
      select * from match_request
       where activity_type_id = v_rec.activity_type_id
         and school = v_rec.school
         and campus = v_rec.campus
         and status = 'REQUESTING'
       order by created_at asc
    ) loop
      -- 尋找配對對象 v_req_b
      select * into v_req_b
        from match_request r
       where r.activity_type_id = v_rec.activity_type_id
         and r.school = v_rec.school
         and r.campus = v_rec.campus
         and r.status = 'REQUESTING'
         and r.id <> v_req_a.id
         and r.earliest_start <= v_req_a.latest_start
         and r.latest_start >= v_req_a.earliest_start
         and not exists (
           -- 避雷降權檢查 (match_history_avoidance，Pair 正規化)
           select 1 from match_history_avoidance mha
            where mha.expire_at > now()
              and (
                (mha.user_a_id = least(v_req_a.owner_id, r.owner_id)
                 and mha.user_b_id = greatest(v_req_a.owner_id, r.owner_id))
              )
         )
       limit 1;

      if v_req_b.id is not null then
        -- 執行撮合提交
        perform commit_match(v_req_a.id, v_req_b.id);
        v_match_count := v_match_count + 1;
      end if;
    end loop;
  end loop;

  return v_match_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. propose_location：加 p_campus 參數（否則核准後的地點沒有 campus，無法參與
--    任何撮合——campus 現在是 NOT NULL）
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
-- 6. propose_activity_location / vote_activity_location (新)
--    候選地點僅限該 activity 的 (school, campus) 範圍內、既有 location 表已核准
--    的地點；提案 = 建立候選 + 自動幫提案者投一票；投票 = upsert，可改票。
--    公開透明（見 RLS，跟 pending_confirmation 的刻意不歸因設計相反）。
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
-- 7. fn_start_activities (新，首次實作)：A2 轉移的觸發點，第一次真正落地成 SQL
--    （§9 文件過去只有描述，沒有對應函式，見 RPC_COVERAGE.md 既有落差記錄）。
--    比照 fn_run_matching_engine/fn_cleanup_pending_confirmations 的既有慣例，
--    這輪只做成 callable function，不掛 pg_cron.schedule。
--
--    鎖定候選地點：得票最高者勝出，同票取最早提案（created_at）者勝出；候選
--    只有 1 個時，這條排序邏輯自然選中它，不需要特判。零候選時
--    activity_location_id 維持 NULL，不代替使用者決定（見下方 fn_remind_...）。
-- -----------------------------------------------------------------------------

create or replace function fn_start_activities()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity record;
  v_winner   uuid;
  v_count    int := 0;
begin
  for v_activity in (
    select * from activity
     where status = 'MATCHED' and start_time <= now()
  ) loop
    if v_activity.activity_location_id is null then
      select o.location_id into v_winner
        from activity_location_option o
       where o.activity_id = v_activity.id
       order by (
         select count(*) from activity_location_vote v
          where v.activity_id = o.activity_id and v.location_id = o.location_id
       ) desc, o.created_at asc
       limit 1;

      if v_winner is not null then
        update activity set activity_location_id = v_winner where id = v_activity.id;
      end if;
      -- 零候選：activity_location_id 維持 NULL，不做任何「代替使用者決定」的
      -- 動作；Meeting Point（未來實作）獨立於此欄位是否鎖定可用，見 SPEC v1.11。
    end if;

    update activity set status = 'ONGOING' where id = v_activity.id;

    insert into notification (user_id, event_type, payload)
    select am.user_id, 'ACTIVITY_REMINDER', jsonb_build_object('activity_id', v_activity.id)
      from activity_member am where am.activity_id = v_activity.id and am.status = 'JOINED';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. fn_remind_missing_location_candidates (新)：start_time 前 N 分鐘
--    （app_config.location_reminder_lead_minutes，預設 30）仍零候選 → 提醒全體
--    成員提案，不等到 fn_start_activities 才被動接受 NULL 結果。
--    去重靠 notification 表本身既有資料查詢，不額外加欄位（比照
--    known_member_count/Reliability 分數不落地存欄位的既有原則）。
-- -----------------------------------------------------------------------------

create or replace function fn_remind_missing_location_candidates()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity record;
  v_lead     interval;
  v_count    int := 0;
begin
  select fn_get_config_interval('location_reminder_lead_minutes') into v_lead;

  for v_activity in (
    select a.* from activity a
     where a.status = 'MATCHED'
       and a.start_time > now()
       and a.start_time <= now() + v_lead
       and not exists (
         select 1 from activity_location_option o where o.activity_id = a.id
       )
       and not exists (
         select 1 from notification n
          where n.event_type = 'LOCATION_NOT_YET_PROPOSED'
            and (n.payload->>'activity_id')::uuid = a.id
       )
  ) loop
    insert into notification (user_id, event_type, payload)
    select am.user_id, 'LOCATION_NOT_YET_PROPOSED',
           jsonb_build_object('activity_id', v_activity.id, 'start_time', v_activity.start_time)
      from activity_member am where am.activity_id = v_activity.id and am.status = 'JOINED';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
