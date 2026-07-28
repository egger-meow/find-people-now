-- =============================================================================
-- 修正 bug：get_or_create_invite_link 從未真的能跑（search_path 漏掉 extensions）
-- =============================================================================
-- 接續 20260724125000_enable_pgcrypto.sql 的發現：pgcrypto 其實早就裝了，只是
-- 裝在 `extensions` schema（Supabase 標準做法），不是 `public`。這個函式（跟
-- 20260724122600_delete_account_guard.sql:474-509 疊加 ACCOUNT_DELETED 檢查後
-- 的最新版本）跟全庫其他 SECURITY DEFINER 函式一樣寫 `set search_path =
-- public`，沒有把 `extensions`包進去，所以呼叫 `gen_random_bytes` 時解析不到
-- ——這不是 pgcrypto 本身沒裝，是這個函式的 search_path 範圍不夠。
--
-- 重新貼上 20260724122600_delete_account_guard.sql 那版（含 ACCOUNT_DELETED
-- guard）的完整函式體，只多把 `extensions` 加進 `search_path`。
-- =============================================================================

create or replace function get_or_create_invite_link(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_token   text;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select invite_token into v_token
    from match_request
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  if v_token is null then
    v_token := encode(gen_random_bytes(12), 'hex');
    update match_request
       set invite_token = v_token
     where id = p_request_id;
  end if;

  return v_token;
end;
$$;
