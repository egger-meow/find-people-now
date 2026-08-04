-- =============================================================================
-- Activity Location：刪除 ACTIVITY_LOCATION_LOCKED，改成持續即時計票（v1.37）
--
-- 背景（真實使用者回報，2026-08-04）：一個活動到 start_time 時零候選（見設計
-- 備註 33，`fn_start_activities()` 不代替使用者決定，`activity_location_id`
-- 維持 NULL），status 因此變成 ONGOING。使用者在這之後才想到要提案/投票，
-- 前端「還沒有人提案候選地點」畫面照常顯示提案/投票按鈕（`activity_location_id`
-- 仍是 NULL），但 RPC 一律回 ACTIVITY_LOCATION_LOCKED——因為舊版判斷式是
-- `status <> 'MATCHED' or activity_location_id is not null`，只要活動一過
-- start_time 就整組鎖死，不管有沒有候選、有沒有鎖定結果。體驗上等於「明明
-- 畫面叫你提案，一按就報錯」，且前端把這個內部錯誤碼原樣印在畫面上
-- （`新增失敗：activityLocationLock`），對一般使用者完全無意義。
--
-- 修法：整個刪掉「鎖定後不能再動」這件事，改成跟 Meeting Point/Hint（v1.11.1）
-- 同一種閘門——`activity.status in ('MATCHED', 'ONGOING')` 就能提案/投票，
-- `COMPLETED`/`CANCELLED` 才擋（沿用既有的 ACTIVITY_NOT_ACTIVE，不是新錯誤碼）。
-- `activity_location_id` 不再是「背景任務在 start_time 那一刻寫死一次」的
-- 凍結欄位，改成每次提案/投票後都用同一份計票規則（得票最高者勝出，同票取
-- 最早提案者）重新算一次、即時覆寫——這件事抽成 fn_recompute_activity_location()
-- 共用給 propose_activity_location/vote_activity_location/fn_start_activities
-- 三處呼叫，避免三份計票邏輯各自漂移。零候選時的既有原則不變（設計備註 33）：
-- 沒有任何候選就不寫入任何值，維持 NULL，不代替使用者決定。
--
-- ACTIVITY_LOCATION_LOCKED 這個錯誤碼從此完全從系統移除（migrations 之外的
-- 引用一併清掉：app_exception.dart 的 enum、docs/API.md、docs/STATE_MACHINE.md、
-- docs/SPEC.md §9.1、pgTAP test）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. fn_recompute_activity_location：共用計票規則，寫回 activity.activity_location_id
--    （得票最高者勝出；同票取最早提案 created_at 者；零候選則寫 NULL）
-- -----------------------------------------------------------------------------

create or replace function fn_recompute_activity_location(p_activity_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_winner uuid;
begin
  select o.id into v_winner
    from activity_location_option o
   where o.activity_id = p_activity_id
   order by (
     select count(*) from activity_location_vote v
      where v.activity_id = o.activity_id and v.option_id = o.id
   ) desc, o.created_at asc
   limit 1;

  update activity set activity_location_id = v_winner where id = p_activity_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. propose_activity_location：ACTIVITY_LOCATION_LOCKED → ACTIVITY_NOT_ACTIVE
--    （閘門條件同步比照 update_meeting_point/update_meeting_hint），投票後即時
--    重新計票
-- -----------------------------------------------------------------------------

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

  -- v1.37：不再有「已鎖定就整組擋掉」這件事——提案/投票跟 Meeting Point/Hint
  -- 用同一組閘門，活動結束/取消後才擋
  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
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

  perform fn_recompute_activity_location(p_activity_id);

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. vote_activity_location：同上，ACTIVITY_LOCATION_LOCKED → ACTIVITY_NOT_ACTIVE，
--    投票後即時重新計票
-- -----------------------------------------------------------------------------

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

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
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

  perform fn_recompute_activity_location(p_activity_id);

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. fn_start_activities：不再自己算一次得票（已經被 propose/vote 即時維護），
--    改呼叫 fn_recompute_activity_location 當防禦性保底（冪等，即使從沒人投過
--    票也只是把 NULL 寫回 NULL，不影響「零候選不代選」的既有原則）
-- -----------------------------------------------------------------------------

create or replace function fn_start_activities()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity record;
  v_count    int := 0;
begin
  for v_activity in (
    select * from activity
     where status = 'MATCHED' and start_time <= now()
  ) loop
    perform fn_recompute_activity_location(v_activity.id);

    update activity set status = 'ONGOING' where id = v_activity.id;

    insert into notification (user_id, event_type, payload)
    select am.user_id, 'ACTIVITY_REMINDER', jsonb_build_object('activity_id', v_activity.id)
      from activity_member am where am.activity_id = v_activity.id and am.status = 'JOINED';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
