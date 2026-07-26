-- =============================================================================
-- pending_review view — MVP 唯一審核管道
-- 派生自使用者需求（v1.10）
-- =============================================================================
-- UNION activity_type 與 location 兩張表目前 status = 'PENDING' 的項目，讓 admin
-- 在 Supabase Studio 查這一張 view 就能看到所有排隊中的提案，不用分別開兩張表。
--
-- 這是 MVP 階段唯一的審核渠道：admin 直接在 Supabase Dashboard/Studio 查這張
-- view、手動把對應原表的 status 改成 APPROVED/REJECTED（活動類型審核時一併補
-- default_duration_minutes/default_min_participants/default_max_participants/
-- group_size_step/description，見 activity_type 表定義）。不新建任何 admin 專屬
-- API 或前端頁面。
--
-- 刻意不對 anon/authenticated grant 任何權限（20260724120800_grants.sql 不會
-- 動它）——只有 postgres/service_role 能查得到，PostgREST 完全摸不到。

create view pending_review as
  select
    'ACTIVITY_TYPE'::text as kind,
    id,
    name,
    created_by,
    created_at
  from activity_type
  where status = 'PENDING'
  union all
  select
    'LOCATION'::text as kind,
    id,
    name,
    created_by,
    created_at
  from location
  where status = 'PENDING';
