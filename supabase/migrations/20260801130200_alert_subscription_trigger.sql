-- =============================================================================
-- Alert Subscription — 觸發點 (v1.27)
--
-- 重新定義 submit_request（沿用 20260724122600_delete_account_guard.sql 的
-- 完整驗證順序，一字不改），只在成功轉入 REQUESTING 之後、return 之前，
-- 加一段「通知符合條件的訂閱者」的邏輯。
--
-- 刻意不把 request_id 放進通知 payload：訂閱者要知道的是「這個 (類型,
-- 校區) 現在有機會了，去開一個新的 Request」，不是「去看某人這一筆」——
-- `match_request` 的 RLS 本來就不開放非 owner/成員讀取，就算 payload 帶了
-- id，前端也查不到任何細節，帶進去只是多一個沒有用途的欄位，不帶更乾淨，
-- 跟 get_campus_pulse（v1.26）的聚合、不指名道姓精神一致。
--
-- 不通知自己：v_user_id 剛好也訂閱了同樣的 (類型, 校區) 是可能發生的
-- （沒有理由禁止），但通知「你自己剛送出的東西」沒有資訊價值。
-- =============================================================================

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

  -- 4. PROFILE_INCOMPLETE
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

  -- 6. ACTIVE_ACTIVITY_IN_PROGRESS
  if exists (
    select 1 from activity_member am
    join activity a on a.id = am.activity_id
     where am.user_id = v_user_id
       and am.status = 'JOINED'
       and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS';
  end if;

  -- 7. REQUEST_COOLDOWN_ACTIVE
  select next_request_allowed_at into v_cooldown from app_user where id = v_user_id;
  if v_cooldown is not null and v_cooldown > v_now then
    raise exception using message = 'REQUEST_COOLDOWN_ACTIVE';
  end if;

  -- 8. 單一 REQUESTING 限制
  if exists (select 1 from match_request where owner_id = v_user_id and status = 'REQUESTING') then
    raise exception using message = 'ALREADY_REQUESTING';
  end if;

  -- 9. 24h 時間窗限制
  if v_request.latest_start > v_request.created_at + interval '24 hours' then
    raise exception using message = 'WINDOW_EXCEEDS_24H';
  end if;

  -- 10. 新人低人數門檻檢查
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

  -- v1.27 新增：通知符合條件、仍在有效期內的 Alert Subscription。
  insert into notification (user_id, event_type, payload)
  select s.user_id, 'ALERT_TRIGGERED',
         jsonb_build_object(
           'activity_type_id', v_request.activity_type_id,
           'school', v_request.school,
           'campus', v_request.campus
         )
    from activity_alert_subscription s
   where s.activity_type_id = v_request.activity_type_id
     and s.school = v_request.school
     and s.campus = v_request.campus
     and s.expires_at > v_now
     and s.user_id != v_user_id;

  return v_request;
end;
$$;
