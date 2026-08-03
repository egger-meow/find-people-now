-- =============================================================================
-- 讀書「同伴目標」自由文字比對欄位 —— schema (v1.35)
-- =============================================================================
-- 只綁定「讀書」這個固定活動類型，不比照 skill_level 做成通用 per-type flag——
-- 讀書細項（科目/課程/考試皆可）跟競技程度是兩種不同性質的設定，不需要共用
-- 同一套可擴充機制。
--
-- 兩欄分開存：
--   study_target             使用者原始輸入，未經任何清理。前端顯示（等待室、
--                             活動中成員名單）一律讀這欄，避免使用者覺得自己
--                             打的字被系統悄悄改掉。
--   study_target_normalized  正規化後的字串，撮合比對只用這欄。
-- 兩者都是 null = 不限（wildcard）。
alter table match_request
  add column study_target             text,
  add column study_target_normalized  text;

-- 正規化規則：去除頭尾空白、全形括號/全形空白轉半形、統一小寫。
-- 不做模糊比對，只做確定性字串清理；正規化後為空字串一律視為 null（wildcard）。
--
-- 順序刻意是「先轉半形、再去頭尾空白」，不是反過來：btrim() 預設只認得半形
-- 空白字元，如果輸入頭尾剛好是全形空白（U+3000），先 btrim 會因為不認得
-- 而略過不裁切，之後 translate() 才把它轉成半形空白，結果變成頭尾殘留一個
-- 半形空白，沒有真的被裁掉。先 translate 統一轉成半形字元，再 btrim，才能
-- 正確裁掉「原本是全形」的頭尾空白。
create or replace function fn_normalize_study_target(p_text text)
returns text
language sql
immutable
as $$
  select nullif(lower(btrim(translate(p_text, '（）　', '() '))), '')
$$;
