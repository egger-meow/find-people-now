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

## Functions with no implementation (documented, don't exist in the DB)

Grepped the full `supabase/migrations/` tree for these three identifiers —
zero matches for any of them as a function definition:

| docs/API.md | Status |
|---|---|
| §3.4 `join_request(request_id)` | **not implemented** — no such function anywhere. Only `join_request_by_token` (§3.8) exists. |
| §3.5 `leave_request(request_id)` | **not implemented** |
| §5.1 `respond_downgrade(downgrade_request_id, agree)` | **not implemented** — `downgrade_request`/`downgrade_consent` tables exist and are typed (see `lib/generated/`), but nothing writes to them from a client-callable RPC. |

No wrapper functions are written for these three. If the frontend needs
them, they must be added to the backend first.

## Error codes documented in API.md but never raised

| Code | Documented at | What actually happens instead |
|---|---|---|
| `NAME_BLACKLISTED` | §2.3 `propose_activity_type` | No blacklist check exists at all (verified: no `blacklist` string anywhere in migrations). Only empty-name (`INVALID_INPUT`, itself undocumented) and exact-duplicate (`DUPLICATE_TYPE_NAME`) are checked. |
| `INVITE_LINK_REVOKED` | §3 error table | `join_request_by_token` only ever raises `INVITE_LINK_EXPIRED`, for missing/revoked/expired tokens alike (single `where invite_token = ... and revoked_at is null` filter, one raise site). |
| `INVALID_PENDING_CONFIRMATION` | §4 error table | A nonexistent `pending_confirmation_id` raises `NOT_FOUND` (detail `PENDING_CONFIRMATION_NOT_FOUND`) instead, same convention as every other lookup RPC. |
| `ALREADY_RESPONDED` | — | Confirmed *not* raised — matches API.md's own v1.7 note that this code was intentionally removed ("允許反悔"). Listed here only as a confirmation, not a gap. |
| `CONTACT_EXPIRED` | §6 error table | `get_activity_contacts` never throws for this; it returns HTTP 200 with `members[].contacts == null`. Client must branch on null, not catch an exception. |
| `ACTIVITY_ALREADY_ENDED` | §6 error table | Not checked by either `get_activity_contacts` or `cancel_activity_participation`. |
| `ACTIVITY_NOT_ENDED` | §7 error table | `submit_completion_report` has no gate on `activity.status`/`start_time` before accepting a report. |
| `INVALID_ABSENT_TARGET` | §7 error table | `absent_user_ids` is inserted with no check that the ids are actually members of the activity. |

## Error codes raised in practice but not documented

| Code | Raised by | Detail |
|---|---|---|
| `INVALID_INPUT` | `create_request`, `propose_activity_type`, `rematch_vote` | Generic catch-all for malformed input (empty name, bad time bucket, unknown activity type, voting for yourself). Always carries a `detail` distinguishing the case. |
| `INVALID_MIN_PARTICIPANTS` / `INVALID_MAX_PARTICIPANTS` | `create_request` | `min_participants < 2`, or `max_participants < min_participants`. |
| `FORBIDDEN` (detail `NOT_PARTY_TO_CONFIRMATION`) | `respond_pending_confirmation` | Caller is neither request_a's nor request_b's owner. |

## Confirmed exact matches (worth calling out — not everything is a gap)

- `submit_request`'s 9-step validation order (§3.2, "任何未來重構都不能打亂") matches the migration's inline numbered comments exactly, in order.
- `respond_pending_confirmation`'s atomic per-caller-field update + PC1/PC2 transition logic matches §4.2's description exactly, including the 30-minute cooldown write on `confirm=false` (via `fn_get_config_interval('cooldown_minutes')`) and PC1's `commit_match(...)` call.
- `cancel_activity_participation`'s EARLY_CANCEL (≥1h before start) vs LATE_CANCEL split, and the cooldown write only on LATE_CANCEL, matches §6.3.

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
