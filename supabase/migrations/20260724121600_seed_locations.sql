-- =============================================================================
-- Seed — 正式地點清單 (v1.11)
-- NYCU 光復校區 + NTHU 校本部，共 18 筆，皆為 APPROVED（管理員直接核可，非使用者提案）。
-- location 目前無 category 欄位（v1.10/v1.11 皆明確決議不補），故不寫入 category。
-- =============================================================================

insert into location (school, campus, name, status) values
  ('NYCU', '光復', '光復校區籃球場', 'APPROVED'),
  ('NYCU', '光復', '光復校區排球場', 'APPROVED'),
  ('NYCU', '光復', '浩然圖書館', 'APPROVED'),
  ('NYCU', '光復', '二餐', 'APPROVED'),
  ('NYCU', '光復', '女二餐廳', 'APPROVED'),
  ('NYCU', '光復', '研三餐廳', 'APPROVED'),
  ('NYCU', '光復', '竹湖', 'APPROVED'),
  ('NYCU', '光復', '北大門', 'APPROVED'),
  ('NYCU', '光復', '南大門', 'APPROVED'),
  ('NTHU', '校本部', '清大體育館', 'APPROVED'),
  ('NTHU', '校本部', '清大圖書館', 'APPROVED'),
  ('NTHU', '校本部', 'Louisa Coffee 清大圖書館門市', 'APPROVED'),
  ('NTHU', '校本部', 'Defcoffee', 'APPROVED'),
  ('NTHU', '校本部', '成功湖', 'APPROVED'),
  ('NTHU', '校本部', '相思湖', 'APPROVED'),
  ('NTHU', '校本部', '小吃部', 'APPROVED'),
  ('NTHU', '校本部', '水木餐廳', 'APPROVED'),
  ('NTHU', '校本部', '風雲樓', 'APPROVED')
on conflict (school, name) do update set
  campus = excluded.campus,
  status = excluded.status;
