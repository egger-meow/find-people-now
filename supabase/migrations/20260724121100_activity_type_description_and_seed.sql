-- =============================================================================
-- activity_type.description + 官方預設類型「先聚了再說」
-- 派生自使用者需求（v1.10）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. activity_type：新增 description（前端「?」按鈕顯示的玩法說明）
-- -----------------------------------------------------------------------------
-- 審核時由 admin 在 Supabase Dashboard 跟 default_duration_minutes/
-- default_max_participants/group_size_step 一起設定，不進 propose_activity_type
-- 的參數 —— 這支 RPC 本來就不接受這幾個欄位，語意一致（提案者只給 name，
-- 其餘細節都是審核當下由 admin 決定的）。

alter table activity_type
  add column description text;

-- -----------------------------------------------------------------------------
-- 2. 官方預設類型「先聚了再說」：沒有固定活動形式，官方直接提供，不走
--    propose_activity_type 審核流程（比照 seed_defaults.sql 現有 7 個官方類型）
-- -----------------------------------------------------------------------------
-- duration/min/max 依「沒有固定活動形式」的性質評估：90 分鐘（中等長度，不預設
-- 短聚或久留）、5~20 人（明顯寬於其他類型，因為這類型本身不預設固定隊形/場地，
-- 適合鬆散的大型聚會）、group_size_step = null（沒有固定隊形，不該離散化人數選項）。

insert into activity_type (name, status, default_duration_minutes, default_min_participants, default_max_participants, group_size_step, description) values
  ('先聚了再說', 'APPROVED', 90, 5, 20, null,
   '一群人先聚在一起，再看要幹嘛。適合喜歡聊天、或希望對方也很愛聊天的人。');
