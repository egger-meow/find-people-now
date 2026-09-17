-- =============================================================================
-- Web 推播訂閱表、帳號切換清理 RPC 與 PENDING_CONFIRMATION 撮合通知補齊
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 推播訂閱表 (user_push_subscription)
-- -----------------------------------------------------------------------------
create table if not exists user_push_subscription (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references app_user (id) on delete cascade,
  endpoint    text not null,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint uq_user_push_endpoint unique (endpoint)
);

create index if not exists idx_user_push_sub_user on user_push_subscription (user_id);

alter table user_push_subscription enable row level security;

create policy own_push_subscriptions_select
  on user_push_subscription for select
  using (user_id = auth.uid());

create policy own_push_subscriptions_delete
  on user_push_subscription for delete
  using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 2. 儲存推播訂閱 RPC (save_push_subscription)
-- 帳號切換安全保證：若 endpoint 已存在於其他 user_id，先刪除舊記錄，確保此
-- 瀏覽器端點僅屬於當前登入者，防止切換帳號後推播外洩給前一位使用者。
-- -----------------------------------------------------------------------------
create or replace function save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
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
    raise exception using message = 'UNAUTHORIZED', detail = 'AUTH_REQUIRED';
  end if;

  if p_endpoint is null or length(trim(p_endpoint)) = 0 then
    raise exception using message = 'INVALID_INPUT', detail = 'ENDPOINT_REQUIRED';
  end if;

  if p_p256dh is null or length(trim(p_p256dh)) = 0 or p_auth is null or length(trim(p_auth)) = 0 then
    raise exception using message = 'INVALID_INPUT', detail = 'KEYS_REQUIRED';
  end if;

  -- 移除同一個 endpoint 的任何舊綁定（即使屬於別的使用者）
  delete from user_push_subscription where endpoint = p_endpoint;

  insert into user_push_subscription (user_id, endpoint, p256dh, auth, user_agent, updated_at)
  values (v_user_id, p_endpoint, p_p256dh, p_auth, p_user_agent, now());
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. 移除推播訂閱 RPC (remove_push_subscription)
-- 登出或關閉通知時主動清理
-- -----------------------------------------------------------------------------
create or replace function remove_push_subscription(
  p_endpoint text
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
    return;
  end if;

  delete from user_push_subscription
   where endpoint = p_endpoint
     and user_id = v_user_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. 清理失效推播端點 RPC (cleanup_stale_push_subscriptions)
-- 供 Edge Function 在收到 Push Service 404/410 (Gone) 時整批清除過期訂閱
-- -----------------------------------------------------------------------------
create or replace function cleanup_stale_push_subscriptions(
  p_endpoints text[]
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted int := 0;
begin
  if p_endpoints is null or array_length(p_endpoints, 1) is null then
    return 0;
  end if;

  delete from user_push_subscription
   where endpoint = any(p_endpoints);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. 授權 Grants
-- -----------------------------------------------------------------------------
grant select, delete on user_push_subscription to authenticated;
grant execute on function save_push_subscription(text, text, text, text) to authenticated;
grant execute on function remove_push_subscription(text) to authenticated;
revoke execute on function cleanup_stale_push_subscriptions(text[]) from public, anon, authenticated;
grant execute on function cleanup_stale_push_subscriptions(text[]) to service_role;

-- -----------------------------------------------------------------------------
-- 6. commit_match 補齊 PENDING_CONFIRMATION 通知
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
  v_req_a match_request;
  v_req_b match_request;
  v_total int;
  v_pc_id uuid;
begin
  select * into v_req_a from match_request where id = p_request_a_id for update;
  select * into v_req_b from match_request where id = p_request_b_id for update;

  if v_req_a is null or v_req_b is null then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_req_a.status <> 'REQUESTING' or v_req_b.status <> 'REQUESTING' then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  select count(*) into v_total
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
    )
    returning id into v_pc_id;

    update match_request set status = 'PENDING_CONFIRMATION' where id in (p_request_a_id, p_request_b_id);

    -- 向雙方成員發送 PENDING_CONFIRMATION 通知（對稱不歸因，各帶收件者自己的 request_id）
    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_a_id, 'pending_confirmation_id', v_pc_id)
      from request_member rm
     where rm.request_id = p_request_a_id and rm.status = 'JOINED';

    insert into notification (user_id, event_type, payload)
    select rm.user_id, 'PENDING_CONFIRMATION'::notification_event_type,
           jsonb_build_object('request_id', p_request_b_id, 'pending_confirmation_id', v_pc_id)
      from request_member rm
     where rm.request_id = p_request_b_id and rm.status = 'JOINED';

    return null;
  end if;
end;
$$;
