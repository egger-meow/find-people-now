-- =============================================================================
-- 使用者主動封鎖 — RPC（v1.17）
-- 派生自 docs/API.md（block_user/unblock_user，本輪新增）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: block_user
-- 冪等：重複呼叫只會覆寫 reason，不會噴錯、不會產生第二筆。
-- 不檢查 suspended_until——封鎖是自我保護行為，被停權中的使用者仍應能封鎖騷擾自己的人。
-- -----------------------------------------------------------------------------

create or replace function block_user(
  p_blocked_id  uuid,
  p_reason      text default null
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

  if p_blocked_id = v_user_id then
    raise exception using message = 'INVALID_INPUT', detail = 'CANNOT_BLOCK_SELF';
  end if;

  if not exists (select 1 from app_user where id = p_blocked_id) then
    raise exception using message = 'NOT_FOUND', detail = 'BLOCKED_USER_NOT_FOUND';
  end if;

  insert into user_block (blocker_id, blocked_id, reason)
  values (v_user_id, p_blocked_id, p_reason)
  on conflict (blocker_id, blocked_id) do update set
    reason = excluded.reason;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: unblock_user
-- 冪等：找不到對應記錄也視為成功（無副作用可還原）。
-- -----------------------------------------------------------------------------

create or replace function unblock_user(
  p_blocked_id  uuid
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

  delete from user_block where blocker_id = v_user_id and blocked_id = p_blocked_id;
end;
$$;
