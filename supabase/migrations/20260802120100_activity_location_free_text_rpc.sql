-- =============================================================================
-- Activity Location 投票候選開放自由輸入（v1.30）：RPC 改寫
-- 依附 20260802120000_activity_location_free_text_schema.sql 的 schema 變更
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. propose_activity_location：p_location_id 改成可選，新增可選的
--    p_custom_name——恰好給一個，否則 INVALID_INPUT。給 location_id 時邏輯跟
--    v1.11 完全相同（APPROVED + 同 (school, campus) 範圍）；給 custom_name 時
--    不做任何審核／範圍檢查，直接建立僅該活動可見的候選（trim + 1~40 字，
--    DB CHECK 已有下限防線，這裡先擋一次給更好的錯誤訊息）。
-- -----------------------------------------------------------------------------

-- 舊簽名是 (uuid, uuid)（兩個必填參數）；新簽名多一個帶預設值的參數後，
-- Postgres 會視為不同重載而非取代，两者共存時 propose_activity_location(uuid, uuid)
-- 這種 2 參數呼叫會變成「候選不唯一」而報錯（同 vote_activity_location 的
-- 參數改名問題，但這裡是參數數量變化，一樣需要先 drop 舊簽名）。
drop function if exists propose_activity_location(uuid, uuid);

create or replace function propose_activity_location(
  p_activity_id  uuid,
  p_location_id  uuid default null,
  p_custom_name  text default null
)
returns activity_location_option
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_activity    activity;
  v_loc         location;
  v_custom_name text;
  v_result      activity_location_option;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if (p_location_id is null) = (p_custom_name is null) then
    raise exception using message = 'INVALID_INPUT', detail = 'EXACTLY_ONE_LOCATION_SOURCE';
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

  if p_location_id is not null then
    select * into v_loc from location where id = p_location_id;
    if not found or v_loc.status <> 'APPROVED'
       or v_loc.school <> v_activity.school or v_loc.campus <> v_activity.campus then
      raise exception using message = 'INVALID_CAMPUS_SCOPE', detail = 'LOCATION_NOT_IN_ACTIVITY_SCOPE';
    end if;

    insert into activity_location_option (activity_id, location_id, proposed_by)
    values (p_activity_id, p_location_id, v_user_id)
    on conflict (activity_id, location_id) do nothing
    returning * into v_result;

    -- 該地點已是既有候選（他人先提過）：提案動作退化成投票，不算錯誤
    if v_result.id is null then
      select * into v_result from activity_location_option
       where activity_id = p_activity_id and location_id = p_location_id;
    end if;
  else
    v_custom_name := trim(p_custom_name);
    if char_length(v_custom_name) = 0 or char_length(v_custom_name) > 40 then
      raise exception using message = 'INVALID_INPUT', detail = 'CUSTOM_NAME_LENGTH';
    end if;

    insert into activity_location_option (activity_id, custom_name, proposed_by)
    values (p_activity_id, v_custom_name, v_user_id)
    on conflict (activity_id, lower(custom_name)) where custom_name is not null do nothing
    returning * into v_result;

    -- 同活動已有同名（大小寫不敏感）自訂候選：同上，退化成投票
    if v_result.id is null then
      select * into v_result from activity_location_option
       where activity_id = p_activity_id and lower(custom_name) = lower(v_custom_name);
    end if;
  end if;

  insert into activity_location_vote (activity_id, user_id, option_id)
  values (p_activity_id, v_user_id, v_result.id)
  on conflict (activity_id, user_id) do update set option_id = excluded.option_id, voted_at = now();

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. vote_activity_location：p_location_id → p_option_id（投給候選記錄本身，
--    不再投給地點——custom_name 候選沒有 location_id 可投，見 schema migration
--    的 activity_location_vote 欄位變更說明）
-- -----------------------------------------------------------------------------

-- CREATE OR REPLACE 不允許改參數名稱（即使型別/順序不變），p_location_id →
-- p_option_id 需要先 drop 舊簽名
drop function if exists vote_activity_location(uuid, uuid);

create or replace function vote_activity_location(
  p_activity_id uuid,
  p_option_id   uuid
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
     where id = p_option_id and activity_id = p_activity_id
  ) then
    raise exception using message = 'NOT_FOUND', detail = 'LOCATION_OPTION_NOT_FOUND';
  end if;

  insert into activity_location_vote (activity_id, user_id, option_id)
  values (p_activity_id, v_user_id, p_option_id)
  on conflict (activity_id, user_id) do update set option_id = excluded.option_id, voted_at = now()
  returning * into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. fn_start_activities：鎖定候選改成依 option id 計票/鎖定（原本依
--    location_id）——activity.activity_location_id 現在存的是
--    activity_location_option.id，見 schema migration 第 3 節。
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
      select o.id into v_winner
        from activity_location_option o
       where o.activity_id = v_activity.id
       order by (
         select count(*) from activity_location_vote v
          where v.activity_id = o.activity_id and v.option_id = o.id
       ) desc, o.created_at asc
       limit 1;

      if v_winner is not null then
        update activity set activity_location_id = v_winner where id = v_activity.id;
      end if;
      -- 零候選：activity_location_id 維持 NULL，不做任何「代替使用者決定」的
      -- 動作；Meeting Point 獨立於此欄位是否鎖定可用，見 SPEC v1.11。
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
