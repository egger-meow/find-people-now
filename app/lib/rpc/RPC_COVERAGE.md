# RPC coverage: docs/API.md vs supabase/migrations/

Cross-checked 2026-07-26 by reading every `create or replace function` in
`supabase/migrations/*.sql` against every `rpc:` line in `docs/API.md`, one
function at a time. Verified with `flutter test test/rpc_smoke_test.dart`
against a local `supabase start` instance (see repo root README for the run
log).

## Why no tool generated any of this

Neither `supadart` nor `supabase_codegen_flutter` (the two actively
maintained Dart codegen tools for Supabase) reads PostgREST's `/rpc/*`
OpenAPI paths — both only parse the table/view `definitions` section of the
swagger doc. There is no Dart equivalent of TypeScript's
`Database['public']['Functions']`. Every file in this directory (except the
supadart-generated table classes it imports) is hand-written and manually
verified against the SQL, not generated.

## v1.9 update: GRANTs, respond_downgrade, leave_request, join_request removal

Four things changed since the cross-check below was first written (still
2026-07-26, same day, after the user reviewed the initial findings):

1. **GRANT bug fixed.** `supabase/migrations/20260724120800_grants.sql` adds
   the table-level SELECT/UPDATE grants every `(PostgREST)`-tagged endpoint
   in API.md needs — see that migration's own header comment for the full
   root-cause writeup, and SPEC.md's v1.9 changelog entry for the summary.
   Every `client.from(...)` call in `lib/rpc/` and `test/` now works against
   an `authenticated`-role session; previously several of them only worked
   by accident (SECURITY DEFINER RPCs bypass table grants) or via a
   docker-exec-psql workaround (see `test/rpc_smoke_test.dart`'s comment,
   now historical — the workaround still works but is no longer necessary).
2. **`§5.1 respond_downgrade(downgrade_request_id, agree)` implemented** in
   `supabase/migrations/20260724120900_rpc_respond_downgrade.sql` (previously
   listed below as not-implemented) — wrapped in `lib/rpc/downgrade_rpc.dart`,
   covered by `supabase/tests/database/03_respond_downgrade.test.sql` (7
   pgTAP assertions: FORBIDDEN, partial-agree stays PENDING, ALREADY_RESPONDED,
   full-agree → APPROVED, any-disagree → immediate REJECTED,
   CONSENT_WINDOW_CLOSED, and the ERD note-21 target_size app-layer guard).
   Only the user-facing *response* half — the RPC that *creates*
   `downgrade_request` rows is a background-task responsibility (API.md §9
   "Request 過期") and is still unimplemented; API.md §5.1 itself says so
   ("發起端是系統（Matching Engine),沒有使用者發起的 endpoint").
3. **`§3.5 leave_request(request_id)` implemented** in
   `supabase/migrations/20260724121000_rpc_leave_request.sql` — wrapped as
   `leaveRequest()` in `lib/rpc/match_request_rpc.dart`, covered by
   `supabase/tests/database/04_leave_request.test.sql` (5 pgTAP assertions).
   Evaluated first, not assumed: `cancel_request` is strictly
   `owner_id = auth.uid()`-scoped, so a member who joined via invite link
   (§3.8) had *no* way to detach themselves before this — a real gap, not a
   hypothetical one. Owner-only calls get `FORBIDDEN` (must use
   `cancel_request` instead); post-match calls get `REQUEST_NOT_OPEN`.
4. **`§3.4 join_request(request_id)` removed from API.md**, not implemented.
   Confirmed there is no UI path that would ever call a non-token join — the
   only invite mechanism since v1.5 is `join_request_by_token` (§3.8); v1.5's
   changelog entry #1 explicitly says "v1 沒有 Friend entity、不存任何朋友關係資料"
   confirming there was never a "browse other people's Requests" concept for
   this to serve. Design leftover from before invite tokens existed, same
   category as the already-removed `create_request` `invited_user_ids`
   parameter — not a missing implementation. See SPEC.md's v1.9 changelog
   entry #4 and API.md §3's new removal note (row number not backfilled).

## v1.10 update: activity_type.description + location review + pending_review view

Three more things added after v1.9, same day:

1. **`activity_type.description`** (nullable text) added in
   `supabase/migrations/20260724121100_activity_type_description_and_seed.sql`,
   plus a seeded official type "先聚聚看" (`status='APPROVED'`, not routed
   through `propose_activity_type` — same pattern as the other 7 seeded
   types). `description` is admin-set at Dashboard review time alongside
   `default_duration_minutes` etc., not a `propose_activity_type` parameter,
   so no RPC signature changed.
2. **`location` review mechanism added**, mirroring `activity_type`:
   `supabase/migrations/20260724121200_location_review.sql` adds
   `status` (reuses the existing `activity_type_status` enum — not a new
   type) and `created_by` to `location`, updates `active_locations_select`
   RLS to `(is_active and status = 'APPROVED') or created_by = auth.uid()`
   (exact mirror of `activity_type`'s `approved_types_select`), and adds
   `propose_location(name, school)`. **`status` defaults to `'APPROVED'`**
   — opposite of `activity_type`'s `'PENDING'` default — because the normal
   write path for `location` is admin-maintained seed/Dashboard inserts;
   user proposals are the side path, not the main one (see ERD note 25).
   Wrapped as `proposeLocation()` in `lib/rpc/location_rpc.dart`, covered by
   `supabase/tests/database/05_propose_location.test.sql`.
   **Deliberately no keyword-blacklist precheck** — harder to smuggle
   profanity into a place name than an activity-type name, and (found while
   scoping this) `propose_activity_type`'s documented blacklist precheck was
   never actually implemented either (see the never-raised-codes table
   below) — copying a check that doesn't exist for the sibling endpoint
   wasn't worth doing. Left `propose_activity_type` itself untouched this
   pass (out of scope, user explicitly deferred that decision).
3. **`pending_review` view added**
   (`supabase/migrations/20260724121300_pending_review_view.sql`): UNION of
   `activity_type`/`location` rows where `status = 'PENDING'`. Deliberately
   NOT granted to `anon`/`authenticated` (`20260724120800_grants.sql` is
   untouched) — only `postgres`/`service_role` can query it, so it's
   invisible to PostgREST entirely. This is the MVP's only review channel;
   no admin API or frontend page was added.
4. `docs/API.md` §2.4's `GET location` query gained a `status=eq.APPROVED`
   filter alongside the existing `is_active=eq.true`.

## Functions with no implementation (documented, don't exist in the DB)

`§9`'s background scheduler jobs (Matching Engine, PENDING_CONFIRMATION
cleanup's `fn_run_matching_engine`/`fn_cleanup_pending_confirmations` exist
as callable functions but nothing schedules them via `pg_cron`; the
`downgrade_request`-creation half of the "Request 過期" job doesn't exist at
all) remain unimplemented — out of scope for this pass, since none of them
are client-callable RPCs.

## Error codes documented in API.md but never raised

| Code | Documented at | What actually happens instead |
|---|---|---|
| `NAME_BLACKLISTED` | §2.3 `propose_activity_type` | No blacklist check exists at all (verified: no `blacklist` string anywhere in migrations). Only empty-name (`INVALID_INPUT`, itself undocumented) and exact-duplicate (`DUPLICATE_TYPE_NAME`) are checked. |
| `INVITE_LINK_REVOKED` | §3 error table | `join_request_by_token` only ever raises `INVITE_LINK_EXPIRED`, for missing/revoked/expired tokens alike (single `where invite_token = ... and revoked_at is null` filter, one raise site). |
| `INVALID_PENDING_CONFIRMATION` | §4 error table | A nonexistent `pending_confirmation_id` raises `NOT_FOUND` (detail `PENDING_CONFIRMATION_NOT_FOUND`) instead, same convention as every other lookup RPC. |
| `ALREADY_RESPONDED` (§4 `respond_pending_confirmation` only) | — | Confirmed *not* raised for this endpoint — matches API.md's own v1.7 note that the code was intentionally removed from §4 ("允許反悔"). §5's `respond_downgrade` is a *different* endpoint and does raise `ALREADY_RESPONDED` (§5's error table still lists it, unlike §4's) — see the confirmed-matches section below. |
| `CONTACT_EXPIRED` | §6 error table | `get_activity_contacts` never throws for this; it returns HTTP 200 with `members[].contacts == null`. Client must branch on null, not catch an exception. |
| `ACTIVITY_ALREADY_ENDED` | §6 error table | Not checked by either `get_activity_contacts` or `cancel_activity_participation`. |
| `ACTIVITY_NOT_ENDED` | §7 error table | `submit_completion_report` has no gate on `activity.status`/`start_time` before accepting a report. |
| `INVALID_ABSENT_TARGET` | §7 error table | `absent_user_ids` is inserted with no check that the ids are actually members of the activity. |

## Error codes raised in practice but not documented

| Code | Raised by | Detail |
|---|---|---|
| `INVALID_INPUT` | `create_request`, `propose_activity_type`, `propose_location` (v1.10), `rematch_vote` | Generic catch-all for malformed input (empty name, bad time bucket, unknown activity type, voting for yourself). Always carries a `detail` distinguishing the case. |
| `INVALID_MIN_PARTICIPANTS` / `INVALID_MAX_PARTICIPANTS` | `create_request` | `min_participants < 2`, or `max_participants < min_participants`. |
| `FORBIDDEN` (detail `NOT_PARTY_TO_CONFIRMATION`) | `respond_pending_confirmation` | Caller is neither request_a's nor request_b's owner. |

## Confirmed exact matches (worth calling out — not everything is a gap)

- `submit_request`'s 9-step validation order (§3.2, "任何未來重構都不能打亂") matches the migration's inline numbered comments exactly, in order.
- `respond_pending_confirmation`'s atomic per-caller-field update + PC1/PC2 transition logic matches §4.2's description exactly, including the 30-minute cooldown write on `confirm=false` (via `fn_get_config_interval('cooldown_minutes')`) and PC1's `commit_match(...)` call.
- `cancel_activity_participation`'s EARLY_CANCEL (≥1h before start) vs LATE_CANCEL split, and the cooldown write only on LATE_CANCEL, matches §6.3.
- `respond_downgrade`'s STATE_MACHINE.md-derived transitions match exactly: any single `DISAGREE` → immediate `REJECTED` without waiting for the rest of the party; only unanimous `AGREE` → `APPROVED`; a second response from the same user → `ALREADY_RESPONDED` (§5's table still lists this code, unlike §4's — see above); and ERD design note 21's "target_size must be below the original min_participants, checked by both the creation and response RPC" is enforced here as an `INVALID_INPUT` guard even though the creation RPC doesn't exist yet to be the first line of defense.

## `tier` in `get_my_reliability()` is not backed by a Postgres enum

`fn_reliability_tier` returns plain `text` ('NEW'/'TRUSTED'/'NORMAL'), not a
Postgres enum column — so this is a case a table-type generator could never
have caught even in principle. Modeled as `ReliabilityTier` in
`auth_profile_rpc.dart` by convention, matching the literal values API.md
documents for §1.4.

## Table-generation notes (supadart)

- All 16 `public.*` base tables generated cleanly, including the two with
  RLS enabled and no SELECT policy (`pending_confirmation`,
  `match_history_avoidance`) — schema introspection via the service-role key
  is independent of RLS grants, but this only means the *Dart type* exists;
  the app must still go through the controlled RPCs (§4.1, etc.) rather than
  `client.from('pending_confirmation')...`, which will return zero rows
  under the anon/authenticated role at runtime.
- **v1.10**: supadart also generated `PendingReview` for the new
  `pending_review` **view** (`lib/generated/pending_review.dart`) — PostgREST
  exposes every object in the `public` schema by default, views included,
  regardless of grants, so the type exists the same way the two RLS-locked
  tables above do. This one is locked down harder than those two: no `grant`
  at all was given to `anon`/`authenticated` (not even a table-privilege
  grant, let alone an RLS policy), so `client.from('pending_review')...`
  403s outright for both roles. The generated type is dead code from the
  app's perspective — it exists only because supadart can't distinguish
  "admin-only Studio view" from "client-facing view" — do not wire it into
  any screen; admin review happens in Supabase Studio, not the app.
- `notification.payload` (jsonb, NOT NULL) generated as `Map<String, dynamic>`
  — not `dynamic`.
- `match_request.acceptable_location_ids` and `completion_report.absent_user_ids`
  (both `uuid[]`) generated as `List<String>`.
- No column in any of the 16 tables is Postgres `interval` — the only use of
  `interval` in the schema is inside `fn_get_config_interval` (an internal
  helper reading `app_config.value`), which never appears in a table row or
  RPC return. supadart's `interval → Duration` conversion (via the generated
  `DurationFromString` extension) exists in the tool but is **not exercised
  anywhere in this codebase** — noted rather than silently assumed to work.
- Found and did not silently accept: supadart's generated `fromJson()`
  substitutes a fabricated default (`''`, `DateTime.fromMillisecondsSinceEpoch(0)`,
  or `TheEnum.values.first`) for any NOT NULL column that comes back null/missing,
  instead of throwing. This is a real footgun if a `.select()` ever omits a
  required column — it fails silently instead of loudly. It only affects
  `lib/generated/*`, not the hand-written `lib/rpc/*` wrapper (which uses
  `as` casts that throw on a type mismatch).
