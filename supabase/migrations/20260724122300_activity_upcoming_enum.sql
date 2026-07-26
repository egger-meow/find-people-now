-- =============================================================================
-- 活動開始前提前提醒：新增 notification_event_type 值 ACTIVITY_UPCOMING
-- 跟既有 ACTIVITY_REMINDER（活動「已經」開始，A2 轉移時發送）刻意區分開——
-- 這個新事件是活動「快」開始（尚未到 start_time），文案與產品意圖都不同，
-- 不能共用同一個事件類型。ALTER TYPE ... ADD VALUE 必須在自己的 transaction/
-- migration 內先落地才能在同一批次的下一個 migration 使用，比照
-- 20260724121400/20260724121700/20260724122100 的既有慣例。
-- =============================================================================

alter type notification_event_type add value if not exists 'ACTIVITY_UPCOMING';
