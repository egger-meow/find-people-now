-- =============================================================================
-- Realtime — 等待室狀態變化訂閱 (frontend round 1)
-- =============================================================================
-- docs/UI_PLAN.md §3「技術要求」：等待室必須用 Supabase Realtime 訂閱
-- match_request 狀態變化（配對成功、PENDING_CONFIRMATION、EXPIRED 皆為背景排程
-- 主動觸發，不能只靠使用者手動刷新）。
--
-- GAP：翻遍既有 migrations 從未執行過 `alter publication supabase_realtime
-- add table ...`，match_request/request_member 的異動從未真正廣播出去——
-- postgres_changes 訂閱在這之前訂了也收不到任何事件。這不是新增功能，是把
-- UI_PLAN §3 已經明講的技術要求實際接通。
--
-- request_member 一併加入：等待室的成員頭像列（同一節）需要在有人加入/退出時
-- 即時反應人數變化，不能只靠使用者手動刷新。
--
-- Realtime 的 postgres_changes 走該表既有的 RLS SELECT policy 授權
-- （my_requests_select / my_request_members_select，20260724120000_init.sql:298-309），
-- 不需要額外開權限。
-- =============================================================================

alter publication supabase_realtime add table match_request;
alter publication supabase_realtime add table request_member;
