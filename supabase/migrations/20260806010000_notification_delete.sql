-- =============================================================================
-- 通知：允許使用者清空自己的收件匣（v1.40）
--
-- 通知頁久了會累積大量已經沒意義的舊活動通知（配對成功/活動開始/集合地點
-- 更新…）跟目前活動的通知混在一起，UI 分區塊之外，也需要能整批清掉——
-- `notification` 這張表本來就已經比照 v1.7「column-level UPDATE 收斂」的
-- 精神走「grant + RLS policy 直接開放 PostgREST」而不是 RPC（見
-- 20260724125200_restrict_app_user_notification_column_grants.sql 頭註解：
-- 使用者只能動自己的收件匣，沒有跨使用者的狀態機語意，不需要
-- SECURITY DEFINER RPC 那層），DELETE 比照同一個既有先例補上，不是新開
-- 一條例外路徑。
-- =============================================================================

grant delete on notification to authenticated;

create policy own_notifications_delete on notification
  for delete using (user_id = auth.uid());
