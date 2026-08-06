-- =============================================================================
-- pgTAP Test — activity_type.sort_order / search_activity_type 排序 (v1.38)
-- 涵蓋：預設值、官方類型的指定排序值、search_activity_type 實際回傳順序、
-- 同 sort_order 時 fallback 到 name、模糊查詢時排序規則一樣生效。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(6);

-- -----------------------------------------------------------------------------
-- 1. 新欄位預設值為 100（使用者提案通過的新類型會落在中段）
-- -----------------------------------------------------------------------------

select is(
  (select column_default from information_schema.columns
    where table_schema = 'public' and table_name = 'activity_type' and column_name = 'sort_order'),
  '100',
  'v1.38：sort_order 預設值為 100，新提案類型自然落在中段'
);

-- -----------------------------------------------------------------------------
-- 2. 運動類（籃球/羽球/跑步/健身）全部是 10
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from activity_type
    where name in ('籃球', '羽球', '跑步', '健身') and sort_order = 10),
  4,
  'v1.38：四個運動類型的 sort_order 都是 10'
);

-- -----------------------------------------------------------------------------
-- 3. 讀書 20、麻將 900（使用者明確指定「讀書其次、麻將墊底」）
-- -----------------------------------------------------------------------------

select is(
  (select sort_order from activity_type where name = '讀書'),
  20,
  'v1.38：讀書排在運動類之後（sort_order = 20）'
);

select is(
  (select sort_order from activity_type where name = '麻將'),
  900,
  'v1.38：麻將墊底（sort_order = 900）'
);

-- -----------------------------------------------------------------------------
-- 4. search_activity_type 實際回傳順序 —— 這才是前端真正看到的東西
-- -----------------------------------------------------------------------------
-- 前端直接照 RPC 回傳順序渲染、不在 client 端重排（見設計備註 51），所以這裡
-- 斷言的是完整順序，不只是欄位值。同 sort_order 內部 fallback 到 name，四個
-- 運動類型的相對順序由中文 collation 決定，這裡照實際結果寫死，避免測試對
-- collation 細節做出比實作更強的假設。

select is(
  (select array_agg(name order by ord)
     from (select name, row_number() over () as ord from search_activity_type(null)) s),
  array['健身', '籃球', '羽球', '跑步', '讀書', '先聚了再說', '吃飯/咖啡/探店', '散步', '桌遊', '麻將'],
  'v1.38：search_activity_type 回傳順序為運動類 → 讀書 → 其餘 → 麻將'
);

-- -----------------------------------------------------------------------------
-- 5. 模糊查詢時排序規則一樣生效（不是只有「全部列出」那條路徑有排序）
-- -----------------------------------------------------------------------------
-- 「球」同時命中籃球（10）與羽球（10）——同 sort_order，驗證 fallback 到 name
-- 之後順序仍然穩定，不會因為加了 where 條件就回到不定序。

select is(
  (select array_agg(name order by ord)
     from (select name, row_number() over () as ord from search_activity_type('球')) s),
  array['籃球', '羽球'],
  'v1.38：模糊查詢結果一樣套用 sort_order/name 排序'
);

select * from finish();

rollback;
