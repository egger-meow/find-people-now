-- =============================================================================
-- Arrival Check（「我到了」）— RPC (v1.22)
--
-- 邊界跟 update_meeting_hint 同一套：只有 JOINED 成員、活動 status in
-- (MATCHED, ONGOING) 時可呼叫，COMPLETED/CANCELLED 後回 ACTIVITY_NOT_ACTIVE
-- （協調動作已無實質對象）。
--
-- 冪等設計：已抵達過的成員再呼叫一次，直接回傳現有 row、不重複通知——避免
-- 使用者手滑連點兩下就洗版全體成員的通知匣。
--
-- 通知刻意不比照 update_meeting_point「廣播給全體 JOINED（含自己）」：抵達者
-- 收到「你已抵達」這種自我通知沒有意義，這裡只發給「除了自己以外」的
-- JOINED 成員。
-- =============================================================================

create or replace function mark_arrived(
  p_activity_id uuid
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_activity    activity;
  v_result      activity_member;
  v_was_already boolean;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  select (arrived_at is not null) into v_was_already
    from activity_member
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED';

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  if v_was_already then
    select * into v_result from activity_member
     where activity_id = p_activity_id and user_id = v_user_id;
    return v_result;
  end if;

  update activity_member
     set arrived_at = now()
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  returning * into v_result;

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MEMBER_ARRIVED',
         jsonb_build_object(
           'activity_id', p_activity_id,
           'arrived_user_id', v_user_id,
           'display_name', (select display_name from app_user where id = v_user_id)
         )
    from activity_member am
   where am.activity_id = p_activity_id and am.status = 'JOINED' and am.user_id != v_user_id;

  return v_result;
end;
$$;
