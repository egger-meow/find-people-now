-- =============================================================================
-- app_user.onboarding_seen_at（v1.20）
-- 派生自 docs/UI_PLAN.md 第 11.1 節：只在使用者第一次登入、且此欄位為 null
-- 時自動跳出新手上手引導卡片，看過一次（或按叉叉關閉）後寫入，不再自動跳出。
--
-- 不新增 RPC：既有 `grant select, update on app_user to authenticated`
-- （20260724120800_grants.sql）與 `own_profile_update` RLS policy（id =
-- auth.uid()，20260724120000_init.sql）已完整覆蓋，前端直接 PATCH app_user 即可。
-- =============================================================================

alter table app_user
  add column onboarding_seen_at timestamptz;
