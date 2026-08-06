-- =============================================================================
-- Fix Supabase Advisor CRITICAL findings: RLS Disabled in Public (app_config),
-- Security Definer View (pending_review)
-- =============================================================================
-- Both objects are already deliberately excluded from client-facing grants
-- (see 20260724120800_grants.sql's header, "DELIBERATELY EXCLUDED" section) —
-- app_config has no grant to anon/authenticated at all, pending_review has
-- none either, and per that same migration's investigation, Supabase no
-- longer auto-grants new public tables, so neither is actually reachable via
-- PostgREST today (no base grant -> 403 before RLS is even evaluated).
--
-- Advisor flags them anyway because that safety currently rests on a single
-- lock ("nobody granted it"), the same design already rejected for
-- pending_confirmation / match_history_avoidance — those additionally enable
-- RLS with zero policies as a second, grant-independent lock (see
-- 20260724120050_v1_6_schema_sync.sql). This migration brings app_config and
-- pending_review up to the same two-lock standard, closing both Advisor
-- CRITICAL findings without changing any current behavior: internal
-- SECURITY DEFINER RPCs and Studio access (postgres/service_role) bypass RLS
-- regardless (table owner + bypassrls).
-- =============================================================================

-- app_config: RLS Disabled in Public -----------------------------------------
-- No policies added — deny-all by design, matching pending_confirmation /
-- match_history_avoidance. Admin edits stay via the Dashboard Table Editor
-- (connects as postgres, bypasses RLS); internal reads go through
-- fn_get_config_interval, always called from within a SECURITY DEFINER RPC.
alter table app_config enable row level security;
revoke all on app_config from anon, authenticated;

-- pending_review: Security Definer View --------------------------------------
-- security_invoker = true means the view now enforces the *querying* role's
-- own RLS/grants on activity_type and location instead of running with the
-- view owner's privileges — removing the definer-rights footgun even if a
-- future migration accidentally grants access to this view.
alter view pending_review set (security_invoker = true);
revoke all on pending_review from anon, authenticated;
