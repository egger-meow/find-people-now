-- =============================================================================
-- activity_type.sort_order — 活動類型的顯示順序（v1.38）
--
-- 使用者回報：類型清單目前一律 `order by name`（見 20260724120250 的
-- search_activity_type），也就是照中文字面排序，實際結果是「先聚了再說 / 咖啡 /
-- 健身 / 散步 / 桌遊 / 麻將 / 籃球 / 羽球 / 讀書 / 跑步」這種對使用者毫無意義的
-- 順序。訴求是運動類優先、讀書其次、麻將墊底。
--
-- 做法比照設計備註 22（`group_size_step`）與 v1.34（`skill_level_enabled`）已經
-- 建立的「per-type 設定欄位」模式：加一個 admin 可在 Studio 直接調的欄位，不開
-- 「類別（category）」表也不加 enum。刻意不做 category：
--   1. 目前唯一的需求是「排序」，不是「分組顯示」——加 category 卻不分組渲染，
--      就只是一個沒人讀的死欄位（同設計備註 35 對 `location.category` 的判斷）。
--   2. category 無法表達「同一類別內部誰先誰後」，最後還是要再加一個排序欄位，
--      等於兩個欄位表達一件事（同設計備註 22 反對 `group_size_mode` 的理由）。
--
-- 數值刻意留大間隔（10/20/100/900）而非 1/2/3：admin 之後要在兩個既有類型中間
-- 插一個新類型時，不必重排整批既有值。使用者提案通過的新類型走 default 100，
-- 自然落在中段，admin 覺得該調再調。
-- =============================================================================

alter table activity_type
  add column sort_order int not null default 100;

comment on column activity_type.sort_order is
  '顯示排序，小的在前；同值時 fallback 到 name。預設 100（中段），admin 可在 Studio 調整。';

-- 運動類優先
update activity_type set sort_order = 10 where name in ('籃球', '羽球', '跑步', '健身');

-- 讀書其次
update activity_type set sort_order = 20 where name = '讀書';

-- 麻將墊底（使用者明確指定）
update activity_type set sort_order = 900 where name = '麻將';

-- 其餘（咖啡/散步/先聚了再說/桌遊）維持 default 100，落在中段。

-- -----------------------------------------------------------------------------
-- search_activity_type：改以 sort_order 為主排序鍵
-- -----------------------------------------------------------------------------
-- 只改 order by，其餘（APPROVED 過濾、模糊比對）完全不動。前端
-- （app/lib/match/create_request_screen.dart 的類型選擇）直接照 RPC 回傳順序
-- 渲染，不另外在 client 端排序——排序規則屬於 admin 可調的營運設定，跟
-- app_config 的既有精神一致，不該硬編在 client。
create or replace function search_activity_type(p_query text)
returns setof activity_type
language sql
stable
security definer
set search_path = public
as $$
  select *
    from activity_type
   where status = 'APPROVED'
     and (p_query is null or trim(p_query) = '' or name ilike '%' || trim(p_query) || '%')
   order by sort_order, name;
$$;
