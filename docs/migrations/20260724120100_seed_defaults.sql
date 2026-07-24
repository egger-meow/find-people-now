-- =============================================================================
-- Seed：MVP 預設資料（派生自 docs/SPEC.md §1、§5）
-- =============================================================================

-- 預設 4 種活動類型，直接 APPROVED（SPEC §1）
-- default_duration_minutes 留 null → 系統 fallback 60 分鐘（SPEC §5），
-- 之後由 admin 依實際資料設定，不在 seed 階段猜數值
insert into activity_type (name, status, default_duration_minutes) values
  ('籃球', 'APPROVED', null),
  ('咖啡', 'APPROVED', null),
  ('散步', 'APPROVED', null),
  ('讀書', 'APPROVED', null);

-- 地點清單為 SPEC §16 開放問題 4，依校分列（v1.2）
-- （候選：NYCU 光復籃球場／工程館／浩然／女二／竹湖…；NTHU 風雲球場…），
-- 內容定案後在新的 migration 補 insert，不卡 schema：
-- insert into location (school, name) values
--   ('NYCU', '光復籃球場'), ('NYCU', '浩然圖書館'),
--   ('NTHU', '風雲球場'), ...;
