-- =============================================================================
-- v1.8 — 系統可調運營參數 (app_config)
-- 把原本寫死在 RPC function 裡的時間參數抽出成可調整的 key/value 設定表，
-- 冷啟動階段與系統穩定後可用不同數值，不需重新部署即可調整。
-- MVP 階段透過 Supabase Dashboard 的 Table Editor 直接調整，不提供額外的管理 API/RPC。
-- =============================================================================

create table app_config (
  key         text primary key,
  value       text not null,
  description text,
  updated_at  timestamptz not null default now()
);

-- 初始 seed 值沿用目前 SPEC 定案的數值，僅將寫死改為可調，不改變數值本身
insert into app_config (key, value, description) values
  ('cooldown_minutes', '30 minutes',
    '拒絕候選配對 (respond_pending_confirmation 的 DECLINED 分支) 或 LATE_CANCEL 後的請求冷卻時間 (SPEC §6.3)'),
  ('confirm_window_minutes', '10 minutes',
    'PENDING_CONFIRMATION 的確認窗口時長 (SPEC §12.1.2)'),
  ('downgrade_consent_window_minutes', '10 minutes',
    'Downgrade 同意窗口時長 (SPEC §8)。目前尚無 RPC 建立 downgrade_request，此值供未來實作使用');

-- 讀取並轉型為 interval 的共用小工具，避免各呼叫點重複同一段查詢
create or replace function fn_get_config_interval(p_key text)
returns interval
language sql
stable
set search_path = public
as $$
  select value::interval from app_config where key = p_key;
$$;
