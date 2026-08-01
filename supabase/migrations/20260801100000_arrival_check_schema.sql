-- =============================================================================
-- Arrival Check（「我到了」）— schema (v1.22)
--
-- 跟 Meeting Hint 同一種精神：每人在每個 activity 只有一個值、可整體覆寫，
-- 不需要獨立的 append-only 記錄表（不像 Meeting Point 需要「歷史」）。差別是
-- arrived_at 刻意設計成單向（只能從 null 變成一個時間戳，RPC 層不提供清空/
-- 改成 null 的路徑）——「已抵達」不像集合點描述那樣需要能修正打錯字，現實中
-- 也沒有「取消抵達」這回事，MVP 不為手滑誤按開一條 undo 路徑。
-- =============================================================================

alter table activity_member add column arrived_at timestamptz;

-- 必須在自己的 transaction 內先 commit，RPC migration 才能引用這個新 enum 值
-- （PostgreSQL 不允許在同一個 transaction 內新增並使用 enum label，跟
-- MEETING_POINT_UPDATED 那次遇到的限制一樣）。
alter type notification_event_type add value if not exists 'MEMBER_ARRIVED';
