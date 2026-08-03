-- =============================================================================
-- pgTAP Test — RLS self-reference recursion guardrail (generic, all tables)
-- =============================================================================
-- Two prior incidents shared one root cause: a table's own SELECT policy
-- queried itself in its USING (...) clause, which Postgres detects as
-- infinite recursion (42P17, "infinite recursion detected in policy for
-- relation ...") rather than evaluating:
--   - 20260724121900_fix_activity_member_rls_recursion.sql
--   - 20260724124900_fix_request_member_rls_recursion.sql
-- Both were found by accident, months after the policy shipped, the first
-- time anything actually queried the table as the `authenticated` role —
-- every other pgTAP test queries as the postgres superuser (bypassing RLS
-- entirely) or goes through a SECURITY DEFINER RPC. Table-specific
-- regression tests exist for both incidents
-- (07_meeting_point_and_hint.test.sql, 19_waiting_room_realtime_rls.test.sql)
-- but only cover the two tables that already broke once.
--
-- This test generalizes the guardrail instead of the fix: for every table in
-- the public schema with row security enabled, run a bare `select ... limit
-- 1` as the `authenticated` role and assert it never raises 42P17. It does
-- not check *what* rows come back (each feature's own test owns that) or
-- treat any other error (permission denied on the intentionally
-- SELECT-grant-less `pending_confirmation` / `match_history_avoidance`, see
-- 20260724120800_grants.sql, or anything else) as a failure — only 42P17 is
-- the bug class this guards against. Catches a self-referencing policy on
-- any future "member of X can see other members of X" table automatically,
-- without anyone having to remember the fn_is_activity_member /
-- fn_is_request_member helper-function pattern when writing it.
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(2);

-- -----------------------------------------------------------------------------
-- 0. Setup — one throwaway authenticated user. The walk doesn't care whether
--    each table returns 0 or N rows, only whether the query errors with
--    42P17, so no per-table fixture data is needed.
-- -----------------------------------------------------------------------------

create temp table rls_smoke_fixtures (user_id uuid);
create temp table rls_smoke_failures (tablename text);
grant select on rls_smoke_fixtures to authenticated;
grant select, insert on rls_smoke_failures to authenticated;

do $setup$
declare
  v_user_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_user_id, 'rls_smoke@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line)
  values (v_user_id, 'rls_smoke@nycu.edu.tw', 'NYCU', 'RLS Smoke', 'https://avatar.rls_smoke', 'MASTER', 'rls_smoke_line');

  insert into rls_smoke_fixtures values (v_user_id);
end $setup$;

-- -----------------------------------------------------------------------------
-- 1. Walk every RLS-enabled public table as `authenticated`, recording any
--    that raise 42P17. Everything else (permission denied, etc.) is ignored
--    — out of scope for this guardrail.
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_id::text from rls_smoke_fixtures), true);
end $$;

do $walk$
declare
  v_tbl text;
begin
  for v_tbl in
    select tablename from pg_tables where schemaname = 'public' and rowsecurity = true order by tablename
  loop
    begin
      execute format('select 1 from %I limit 1', v_tbl);
    exception
      when sqlstate '42P17' then
        insert into rls_smoke_failures values (v_tbl);
      when others then
        null;
    end;
  end loop;
end;
$walk$;

reset role;

select is(
  (select array_agg(tablename order by tablename) from rls_smoke_failures),
  null::text[],
  'no RLS-enabled table should raise infinite recursion (42P17) for a bare authenticated SELECT'
);

select isnt(
  (select count(*)::int from pg_tables where schemaname = 'public' and rowsecurity = true),
  0,
  'sanity check — at least one RLS-enabled table exists to walk (guards against this test silently checking nothing)'
);

select * from finish();

rollback;
