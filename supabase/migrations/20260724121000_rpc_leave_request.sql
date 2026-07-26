-- =============================================================================
-- rpc: leave_request — docs/API.md §3.5
-- 之前完全沒有實作。評估後確認有真實 UI 場景需要它，而不是文件遺留：
-- `cancel_request`（§3.3）嚴格限定 owner_id = auth.uid()（見
-- 20260724120300_rpc_match_request.sql:246-249），透過邀請連結加入別人 Request
-- 的成員（§3.8 join_request_by_token）完全沒有任何方式可以退出——目前只能
-- 「什麼都不做，賭不會被撮合」或「請 owner 把整個 Request 取消掉，連帶影響
-- 其他已加入的成員」。這跟已經拿掉的 §3.4 join_request（沒有對應 UI 路徑）
-- 不是同一類問題：leave_request 有明確、非假設性的呼叫場景。
--
-- 範圍限定：僅限非 owner 的成員退出。owner 退出的語意已經由 cancel_request
-- 涵蓋（整個 Request 一起結束，而不是留下一個沒有 owner 的 Request）——這不是
-- 疏漏，是刻意不讓 leave_request 處理「換 owner」這種本次任務未定義的行為。
-- =============================================================================

create or replace function leave_request(p_request_id uuid)
returns match_request
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_request match_request;
  v_member  request_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_request from match_request where id = p_request_id for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_request.owner_id = v_user_id then
    raise exception using message = 'FORBIDDEN', detail = 'OWNER_CANNOT_LEAVE_USE_CANCEL_REQUEST';
  end if;

  select * into v_member
    from request_member
   where request_id = p_request_id and user_id = v_user_id
     for update;

  if not found or v_member.status = 'LEFT' then
    raise exception using message = 'FORBIDDEN', detail = 'NOT_A_MEMBER_OF_REQUEST';
  end if;

  -- 配對成立前的邊界（同 cancel_request 的狀態檢查）：配對後改走 Activity 側的
  -- cancel_activity_participation（§6.3），兩張狀態圖的分界不容混用（API.md §9）
  if v_request.status not in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION') then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'CANNOT_LEAVE_FINISHED_REQUEST';
  end if;

  update request_member
     set status = 'LEFT'
   where request_id = p_request_id and user_id = v_user_id;

  -- 配對成立前退出不記 Reliability 事件（API.md §3.5 明文）
  return v_request;
end;
$$;
