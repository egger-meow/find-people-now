-- =============================================================================
-- 補上 ACCOUNT_DELETED 檢查：這輪六個新功能剩餘的 6 支 auth.uid()-driven RPC
--
-- v1.14 起「所有 auth.uid()-driven RPC 都要檢查 ACCOUNT_DELETED」是持續在
-- 維護的既有慣例（v1.18 submit_report 仍照做，見
-- 20260724124500_report_rpc.sql），這輪六個新功能的 7 支新 RPC 全部漏掉了；
-- mark_arrived 已在 20260801160000_fix_mark_arrived_race.sql 一併補上，
-- 這裡處理剩下的 6 支：update_vibe_tags、submit_feedback、get_campus_pulse、
-- subscribe_activity_alert、unsubscribe_activity_alert、get_my_badges。
--
-- 逐支風險評估（多數即使沒這個檢查也不會被繞過，但都是巧合而非設計，
-- 補上才是穩定的保證）：
--   - update_vibe_tags：活動若 MATCHED/ONGOING，delete_account 已把該成員列
--     轉 CANCELLED，會被既有的 NOT_ACTIVITY_MEMBER 擋下；若活動已 COMPLETED，
--     會被 ACTIVITY_NOT_ACTIVE 擋下。兩條路徑剛好都能間接擋掉，但這是巧合。
--   - submit_feedback／subscribe_activity_alert／unsubscribe_activity_alert：
--     沒有任何既有檢查會間接擋掉已刪除帳號寫入新資料，這 3 支是實質缺口。
--   - get_campus_pulse／get_my_badges：純讀取、自己查自己，沒有資料外洩風險，
--     但比照慣例補齊，不製造「有的 RPC 有查、有的沒有」的不一致。
-- =============================================================================

create or replace function update_vibe_tags(
  p_activity_id uuid,
  p_tags        text[]
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_tags     text[];
  v_tag      text;
  v_result   activity_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if p_tags is not null then
    if array_length(p_tags, 1) > 3 then
      raise exception using message = 'INVALID_INPUT', detail = 'TOO_MANY_TAGS';
    end if;
    foreach v_tag in array p_tags loop
      if char_length(v_tag) > 20 then
        raise exception using message = 'INVALID_INPUT', detail = 'TAG_TOO_LONG';
      end if;
    end loop;
  end if;
  v_tags := case when p_tags is null or array_length(p_tags, 1) is null then null else p_tags end;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  update activity_member
     set vibe_tags = v_tags
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  returning * into v_result;

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  return v_result;
end;
$$;

create or replace function submit_feedback(
  p_message     text,
  p_activity_id uuid default null,
  p_app_version text default null,
  p_device_info text default null
)
returns feedback
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_message text := trim(p_message);
  v_result  feedback;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if v_message is null or v_message = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'MESSAGE_REQUIRED';
  end if;

  if char_length(v_message) > 2000 then
    raise exception using message = 'INVALID_INPUT', detail = 'MESSAGE_TOO_LONG';
  end if;

  insert into feedback (user_id, message, activity_id, app_version, device_info)
  values (v_user_id, v_message, p_activity_id, p_app_version, p_device_info)
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function get_campus_pulse(
  p_school school,
  p_campus text
)
returns table (
  activity_type_id   uuid,
  activity_type_name text,
  request_count      int
)
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

  return query
    select mr.activity_type_id, at.name, count(*)::int
      from match_request mr
      join activity_type at on at.id = mr.activity_type_id
     where mr.status = 'REQUESTING'
       and mr.school = p_school
       and mr.campus = p_campus
     group by mr.activity_type_id, at.name
     order by count(*) desc;
end;
$$;

create or replace function subscribe_activity_alert(
  p_activity_type_id uuid,
  p_school           school,
  p_campus           text,
  p_lookahead_hours  int
)
returns activity_alert_subscription
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_result  activity_alert_subscription;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if not exists (select 1 from activity_type where id = p_activity_type_id) then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_TYPE_NOT_FOUND';
  end if;

  if p_lookahead_hours < 1 or p_lookahead_hours > 24 then
    raise exception using message = 'INVALID_INPUT', detail = 'LOOKAHEAD_HOURS_OUT_OF_RANGE';
  end if;

  if (
    select count(*) from activity_alert_subscription
     where user_id = v_user_id and expires_at > now()
  ) >= 5 then
    raise exception using message = 'TOO_MANY_ALERT_SUBSCRIPTIONS';
  end if;

  insert into activity_alert_subscription (user_id, activity_type_id, school, campus, expires_at)
  values (v_user_id, p_activity_type_id, p_school, p_campus, now() + (p_lookahead_hours || ' hours')::interval)
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function unsubscribe_activity_alert(
  p_subscription_id uuid
)
returns void
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

  delete from activity_alert_subscription
   where id = p_subscription_id and user_id = v_user_id;
end;
$$;

create or replace function get_my_badges()
returns table (
  badge_code text,
  earned     boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_attended     int;
  v_no_show      int;
  v_mutual_count int;
  v_organized    int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select count(*) filter (where event_type = 'ATTENDED'),
         count(*) filter (where event_type = 'NO_SHOW')
    into v_attended, v_no_show
    from user_reliability_event
   where user_id = v_user_id;

  select count(*) into v_mutual_count
    from rematch_vote a
   where a.from_user_id = v_user_id
     and exists (
       select 1 from rematch_vote b
        where b.activity_id = a.activity_id
          and b.from_user_id = a.to_user_id
          and b.to_user_id = v_user_id
     );

  select count(*) into v_organized
    from match_request
   where owner_id = v_user_id and status = 'MATCHED';

  return query
    select 'FIRST_ACTIVITY', v_attended >= 1
    union all
    select 'PUNCTUAL', v_attended >= 3 and v_no_show = 0
    union all
    select 'GREAT_COMPANY', v_mutual_count >= 1
    union all
    select 'ENTHUSIASTIC_ORGANIZER', v_organized >= 3;
end;
$$;
