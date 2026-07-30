-- =============================================================================
-- Realtime — 通知 tab 訂閱失敗 (RealtimeSubscribeException / channelError)
-- =============================================================================
-- 反饋：三台裝置測試，配對後通知頁直接載入失敗，錯誤訊息明講「Please check
-- Realtime is enabled for the given connect parameters ... table: notification」。
--
-- 跟 20260724124800_realtime_match_request.sql 是同一個根因、同一個 GAP：
-- `notification_providers.dart` 的 `notificationsStreamProvider` 一直都在用
-- `.stream()` 訂閱 `notification` 表，但這張表從未被加進
-- `supabase_realtime` publication——postgres_changes 訂閱得到 channelError，
-- 不是新功能，是把既有程式碼已經在做的事情實際接通。
--
-- RLS 走既有的 `notification` SELECT policy（`user_id = auth.uid()`），不需要
-- 額外開權限。
-- =============================================================================

alter publication supabase_realtime add table notification;
