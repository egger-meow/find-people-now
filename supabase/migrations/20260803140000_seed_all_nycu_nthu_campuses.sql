-- =============================================================================
-- 補齊 NYCU/NTHU 全部校區的 seed 地點（v1.32 補充）
-- =============================================================================
-- 目前 location 表只有 NYCU 光復、NTHU 校本部兩個校區有資料，`campusOptionsProvider`
-- （`select distinct campus from location where status='APPROVED'`）derive 出來的
-- 校區清單因此只看得到這兩個——不是資料庫設計限制，純粹是清單內容還沒補齊
-- （SPEC §16 開放問題 4 從 v1.2 就留著）。
--
-- 校區範圍依 SPEC.md v1.11 變更紀錄第 1 點的既有地理事實：陽明交通大學校區橫跨
-- 新竹（光復／博愛／六家）、台北（陽明／北門）、台南（歸仁）三個城市；清華大學
-- 除既有校本部外，另有 2016 年合併新竹教育大學校地而來的南大校區。
--
-- 每個新校區先補一筆「校門口」作為代表地點——刻意不虛構特定館舍名稱（沒有把握
-- 精確到館舍等級的資料，寧可用一定存在、不會出錯的地標），使用者之後可以用
-- v1.30 的自由輸入候選（propose_activity_location(custom_name=...)）在投票時
-- 自己補實際地點，不受這裡的預設清單限制。
-- =============================================================================

insert into location (school, campus, name, status) values
  ('NYCU', '博愛', '博愛校區大門', 'APPROVED'),
  ('NYCU', '六家', '六家校區大門', 'APPROVED'),
  ('NYCU', '陽明', '陽明校區大門', 'APPROVED'),
  ('NYCU', '北門', '北門校區大門', 'APPROVED'),
  ('NYCU', '歸仁', '歸仁校區大門', 'APPROVED'),
  ('NTHU', '南大', '南大校區大門', 'APPROVED')
on conflict (school, name) do update set
  campus = excluded.campus,
  status = 'APPROVED';
