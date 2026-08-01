-- =============================================================================
-- Feedback — RPC (v1.25)
--
-- 不檢查 p_activity_id 是否真的跟呼叫者有關（同 submit_report 對
-- reported_activity_id 的既有處理，見 API.md §11.4）：這欄位只是客服排查用
-- 的情境資訊，不是權限邊界，外鍵本身已保證不能塞一個不存在的 activity_id。
-- =============================================================================

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
