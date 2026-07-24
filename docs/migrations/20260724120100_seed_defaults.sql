-- =============================================================================
-- Seed：MVP 預設資料（派生自 docs/SPEC.md §1、§5）
-- =============================================================================

-- 預設活動類型，直接 APPROVED（SPEC §1，官方預設，不走使用者新增審核流程）
-- 數值對齊 SPEC.md §6.2 / ERD.md 已定案的例子（籃球 6/12/step2、咖啡 2/4/連續）；
-- 散步/讀書/跑步/健身沿用同一組決議模式落地，非 null 臆測值
insert into activity_type (name, status, default_duration_minutes, default_min_participants, default_max_participants, group_size_step) values
  ('籃球', 'APPROVED', 120, 6, 12, 2),
  ('咖啡', 'APPROVED', 60, 2, 4, null),
  ('散步', 'APPROVED', 60, 2, 4, null),
  ('讀書', 'APPROVED', 90, 2, 6, null),
  ('跑步', 'APPROVED', 60, 2, 4, null),
  ('健身', 'APPROVED', 90, 2, 4, null);

-- 地點清單為 SPEC §16 開放問題 4，依校分列（v1.2）
-- （候選：NYCU 光復籃球場／工程館／浩然／女二／竹湖…；NTHU 風雲球場…），
-- 內容定案後在新的 migration 補 insert，不卡 schema：
-- insert into location (school, name) values
--   ('NYCU', '光復籃球場'), ('NYCU', '浩然圖書館'),
--   ('NTHU', '風雲球場'), ...;
