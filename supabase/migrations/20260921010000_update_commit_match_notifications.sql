-- =============================================================================
-- commit_match 依 id 排序鎖定並補齊 PENDING_CONFIRMATION 通知
-- =============================================================================

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
  v_req_a match_request;
  v_req_b match_request;
  v_total int;
begin
  -- 依照 id 嚴格排序鎖定，防止並發 (A, B) 與 (B, A) 交叉死鎖，且無多餘查詢負擔
  if p_request_a_id < p_request_b_id then
    select * into v_req_a from match_request where id = p_request_a_id for update;
    select * into v_req_b from match_request where id = p_request_b_id for update;
  else
    select * into v_req_b from match_request where id = p_request_b_id for update;
    select * into v_req_a from match_request where id = p_request_a_id for update;
  end if;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_req_a.status <> 'REQUESTING' or v_req_b.status <> 'REQUESTING' then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  if v_req_a.activity_type_id <> v_req_b.activity_type_id
     or v_req_a.school <> v_req_b.school
     or v_req_a.campus <> v_req_b.campus then
    raise exception using message = 'INTERNAL_ERROR', detail = 'MISMATCHED_ACTIVITY_TYPE_OR_CAMPUS';
  end if;

  -- 防禦性檢查：兩需求必須存在未來的有效共同時間交集
  if greatest(v_req_a.earliest_start, v_req_b.earliest_start, now()) > least(v_req_a.latest_start, v_req_b.latest_start) then
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  -- 跨活動成員防重檢查：任一成員不得已在進行中/成立中的活動
  if exists (
    select 1
      from request_member rm
      join activity_member am on am.user_id = rm.user_id
      join activity a on a.id = am.activity_id
     where rm.request_id in (p_request_a_id, p_request_b_id)
       and rm.status = 'JOINED'
       and am.status = 'JOINED'
       and a.status in ('MATCHED', 'ONGOING')
  ) then
    raise exception using message = 'ACTIVE_ACTIVITY_IN_PROGRESS', detail = 'MEMBER_ALREADY_IN_ACTIVE_ACTIVITY';
  end if;

  select count(distinct user_id) into v_total
    from request_member
   where request_id in (p_request_a_id, p_request_b_id) and status = 'JOINED';

  -- 分支 1：實際撮合人數 > 2 → 直接建立 Activity (R3a)
  if v_total > 2 then
    return fn_create_activity_from_requests(array[p_request_a_id, p_request_b_id]);

  -- 分支 2：實際撮合人數 <= 2 → 建立 pending_confirmation (R3b)
  else
    insert into pending_confirmation (
      request_a_id, request_b_id, confirm_window_expire_at, status
    ) values (
      p_request_a_id, p_request_b_id, now() + fn_get_config_interval('confirm_window_minutes'), 'PENDING'
    );

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    -- 向雙方成員發送 PENDING_CONFIRMATION 通知（對稱不歸因，各帶收件者自己的 request_id）
    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_a_id)
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_b_id)
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    return null;
  end if;
end;
$$;

revoke execute on function commit_match(uuid, uuid) from public, anon, authenticated;
