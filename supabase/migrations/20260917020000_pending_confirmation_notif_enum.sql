-- =============================================================================
-- 新增 notification_event_type 值 PENDING_CONFIRMATION
--
-- 根因：commit_match 在 2 人撮合成功時轉入 PENDING_CONFIRMATION 狀態，但此前
-- 從未發送通知，導致使用者離開畫面後無法得知已進入 5 分鐘確認窗口而高機率逾時。
--
-- ALTER TYPE ... ADD VALUE 必須在自己的 transaction/migration 內先落地，
-- 才能在同一批次的下一個 migration 供 commit_match 使用，比照既有慣例。
-- =============================================================================

alter type notification_event_type add value if not exists 'PENDING_CONFIRMATION';
