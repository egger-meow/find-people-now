-- =============================================================================
-- pgTAP Test — Advisor CRITICAL findings fix (app_config RLS, pending_review
-- security_invoker), 20260807000000_fix_advisor_rls_findings.sql
-- =============================================================================
-- Asserts the two-lock standard actually landed (RLS enabled + zero policies
-- on app_config; security_invoker on pending_review) and that neither object
-- is queryable as `authenticated` — matching the existing
-- pending_confirmation / match_history_avoidance behavior these two are now
-- meant to mirror.
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(5);

-- -----------------------------------------------------------------------------
-- 1. app_config has row security enabled
-- -----------------------------------------------------------------------------

select ok(
  (select rowsecurity from pg_tables where schemaname = 'public' and tablename = 'app_config'),
  'app_config has row level security enabled'
);

-- -----------------------------------------------------------------------------
-- 2. app_config has zero policies — deny-all, same as pending_confirmation /
--    match_history_avoidance, not a scoped policy that might leak rows
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'app_config'),
  0,
  'app_config has no SELECT/INSERT/UPDATE/DELETE policies — deny-all by design'
);

-- -----------------------------------------------------------------------------
-- 3. pending_review view has security_invoker = true
-- -----------------------------------------------------------------------------

select ok(
  (select 'security_invoker=true' = any(c.reloptions)
     from pg_class c
     where c.relname = 'pending_review' and c.relkind = 'v'),
  'pending_review view has security_invoker = true'
);

-- -----------------------------------------------------------------------------
-- 4. Neither object is queryable as `authenticated` (no base grant -> 403
--    before RLS is even evaluated, same as pending_confirmation today)
-- -----------------------------------------------------------------------------

set local role authenticated;

select throws_ok(
  $$ select 1 from app_config limit 1 $$,
  '42501',
  null,
  'authenticated cannot SELECT app_config (permission denied, no grant)'
);

select throws_ok(
  $$ select 1 from pending_review limit 1 $$,
  '42501',
  null,
  'authenticated cannot SELECT pending_review (permission denied, no grant)'
);

reset role;

select * from finish();

rollback;
