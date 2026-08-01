-- =============================================================================
-- Alert Subscription — RPC (v1.27)
-- =============================================================================

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

  if not exists (select 1 from activity_type where id = p_activity_type_id) then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_TYPE_NOT_FOUND';
  end if;

  -- 上限比照全系統既有的 24 小時視野（WINDOW_EXCEEDS_24H 同一個時間尺度），
  -- 不是任意數字。
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

  -- 冪等：找不到（含本來就不屬於自己的）也視為成功，同 unblock_user 的既有慣例。
  delete from activity_alert_subscription
   where id = p_subscription_id and user_id = v_user_id;
end;
$$;
