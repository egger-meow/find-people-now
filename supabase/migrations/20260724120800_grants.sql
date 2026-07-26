-- =============================================================================
-- GRANT SELECT/UPDATE (matching each table's existing RLS policy set) to
-- `authenticated`, plus full access to `service_role`.
--
-- ROOT CAUSE: this project's migrations never contained a single `grant`
-- statement. RLS policies were correctly defined from day one, but Postgres's
-- table privilege system is a SEPARATE, outer gate — RLS only filters rows
-- for a role that already holds the base SELECT/INSERT/UPDATE/DELETE
-- privilege on the table; without that base grant, every query 403s
-- ("permission denied for table ...", 42501) before RLS is ever evaluated.
-- Supabase historically auto-provisioned every new project with
-- `grant all on all tables in schema public to anon, authenticated,
-- service_role` + a matching `alter default privileges` rule, so this
-- repo's migrations never had to think about it. That platform default
-- changed — new tables are no longer auto-granted — so every
-- `(PostgREST)`-tagged endpoint in docs/API.md (2.1, 2.4, 3.6, 5.2, 6.1, 8.1,
-- 8.2, ...) has been silently 403ing for anon/authenticated/service_role
-- alike. Verified via information_schema.role_table_grants on the local
-- instance before writing this file: every public table had REFERENCES/
-- TRIGGER/TRUNCATE only, no SELECT/INSERT/UPDATE/DELETE, for any of those
-- three roles.
--
-- RPC (SECURITY DEFINER) endpoints were unaffected — they execute as the
-- function owner, not the caller's role. Also confirmed via
-- information_schema.role_routine_grants: every public function already has
-- EXECUTE granted to anon/authenticated (Postgres's unrelated default:
-- EXECUTE on functions is granted to PUBLIC unless explicitly revoked), so
-- no `grant execute` statements are needed in this file.
--
-- POLICY: grant only what each table's existing RLS policy set actually
-- allows (a `for select` policy -> `grant select`; a `for update` policy ->
-- `grant update`) — not a blanket `grant all`. No table below gets
-- insert/delete granted to `authenticated`: every state transition goes
-- through a SECURITY DEFINER RPC by design (docs/API.md §0), and that
-- boundary is the point, not an oversight.
--
-- `pending_confirmation`, `match_history_avoidance`, and `app_config` are
-- DELIBERATELY EXCLUDED here:
--   - `pending_confirmation` / `match_history_avoidance` have RLS enabled
--     with NO select policy at all (see 20260724120050_v1_6_schema_sync.sql)
--     — client access must stay impossible; front-end reads go through
--     get_pending_confirmation_status (SECURITY DEFINER) instead.
--   - `app_config` has RLS not even enabled (see
--     20260724120150_v1_8_app_config.sql) and is admin-only via the
--     Supabase Dashboard Table Editor by design.
-- A future migration adding a new table must explicitly decide its
-- client-facing grants here, the same way it must explicitly decide its RLS
-- policies — do not add a blanket `alter default privileges ... to
-- authenticated` rule to paper over that; per-table intent matters (as the
-- three exclusions above show).
--
-- `service_role` is the trusted backend/admin key, never shipped to the
-- Flutter client (see app/.env.example). It gets full table access plus a
-- default-privilege rule covering future tables, matching Supabase's own
-- hosted-project bootstrap convention for that role specifically.
-- =============================================================================

grant select, update on app_user to authenticated;
grant select            on activity_type to authenticated;
grant select            on location to authenticated;
grant select            on match_request to authenticated;
grant select            on request_member to authenticated;
grant select            on activity to authenticated;
grant select            on activity_member to authenticated;
grant select            on downgrade_request to authenticated;
grant select            on downgrade_consent to authenticated;
grant select            on completion_report to authenticated;
grant select            on user_reliability_event to authenticated;
grant select            on rematch_vote to authenticated;
grant select, update on notification to authenticated;

grant all on all tables in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
