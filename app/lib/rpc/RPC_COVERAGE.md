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
   plus a seeded official type "先聚了再說" (`status='APPROVED'`, not routed
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

## v1.11 update: Matching Engine campus-scope rewrite + Activity Location voting

The user's own summary of this round (see SPEC.md's v1.11 changelog) flagged
two premise mismatches with what was actually in this repo before any code
changed, worth recording here since they're exactly the kind of doc↔code gap
this file exists to track:

- **The "Activity 開始" background job did not exist as SQL.** The user's
  request assumed it was "already a periodically-scanning cron" to piggyback
  the location-lock logic onto. It wasn't — `docs/API.md` §9 only ever
  *described* it; no migration defined a matching function (this is exactly
  the gap the "Functions with no implementation" section below already
  flagged for the other background jobs). `fn_start_activities()` in
  `supabase/migrations/20260724121500_campus_scope_rpc.sql` is the actual
  first implementation, not a modification of a pre-existing function.
- **`location.category` did not exist.** The user's request referenced it as
  "already decided last round" (v1.10); v1.10 only added `status`/
  `created_by`. Not added this round either (see SPEC.md v1.11 changelog and
  ERD note 35) — nothing reads it, adding it now would be a dead column.

Schema/RPC changes, all in `supabase/migrations/20260724121400_campus_scope_schema.sql`
+ `20260724121500_campus_scope_rpc.sql`:

1. **`location.campus`** (text, NOT NULL) added — `school` alone can't express
   "close enough" (NYCU spans 新竹/台北/台南). `match_request`/`activity` both
   dropped `campus_location_id` (precise location FK) in favor of `school` +
   `campus` columns (Matching Scope, a range not a point).
   `match_request.acceptable_location_ids[]` was dropped outright (not kept
   as dead/deprecated) — its "one precise location, reserved for future
   multi-select" premise is incompatible with a model where Request creation
   never names a precise location at all.
2. **`create_request`**: `p_campus_location_id` → `p_campus text`. Validates
   `exists(location where school=caller's school and campus=p_campus and
   status='APPROVED')`, raising the new `INVALID_CAMPUS_SCOPE` (not
   `SCHOOL_LOCATION_MISMATCH`, which is now reserved for `join_request_by_token`'s
   cross-school check only — see ERD note 34 for why the codes were split
   instead of reused).
3. **`fn_run_matching_engine`**: merge key changed from single-column
   `campus_location_id` equality to `(school, campus)` tuple equality.
4. **`commit_match`**: `activity.school`/`campus` copied from the winning
   request pair at commit time; `activity.activity_location_id` starts NULL.
5. **`propose_location(name, school)` → `propose_location(name, school, campus)`**
   — an approved location without a `campus` couldn't satisfy step 2's
   existence check, so it'd be permanently unusable.
6. **Two new tables + two new RPCs** for post-match Activity Location voting:
   `activity_location_option`/`activity_location_vote`,
   `propose_activity_location`/`vote_activity_location` (wrapped in
   `lib/rpc/activity_rpc.dart`). RLS is deliberately transparent to activity
   members — the opposite of `pending_confirmation`'s deliberate opacity —
   since a location preference split among an already-matched group isn't the
   same kind of sensitive information as "who caused the match to fail" (see
   ERD note 31).
7. **`fn_start_activities()`** (new): the A2 trigger point
   (`MATCHED → ONGOING`). Locks the highest-voted candidate (ties broken by
   earliest `created_at`) before flipping status, if a lock hasn't happened
   yet. **Zero-candidate activities are left with `activity_location_id =
   NULL` — not auto-assigned a fallback location** (picking an unrelated
   approved location in-scope would be worse than no answer). Same
   unscheduled-callable-function treatment as `fn_run_matching_engine`/
   `fn_cleanup_pending_confirmations` below — no `pg_cron.schedule` call.
8. **`fn_remind_missing_location_candidates()`** (new): fires
   `LOCATION_NOT_YET_PROPOSED` (new `notification_event_type` value) to all
   members of a `MATCHED` activity that's within
   `app_config.location_reminder_lead_minutes` (default 30) of `start_time`
   and still has zero `activity_location_option` rows. De-duped by querying
   `notification` itself for an existing row of that type+activity, not an
   extra column.
9. `propose_location`'s Dart wrapper (`lib/rpc/location_rpc.dart`) gained the
   `campus` param; `create_request`'s wrapper
   (`lib/rpc/match_request_rpc.dart`) renamed `campusLocationId` → `campus`;
   new `proposeActivityLocation`/`voteActivityLocation` wrappers added to
   `lib/rpc/activity_rpc.dart`; `api_exception.dart` gained
   `invalidCampusScope`/`activityLocationLocked`.

## v1.11.1 update: Meeting Point / Meeting Hint schema + `activity_member` RLS recursion fix

Two independent things landed in this round, kept in separate migrations:

**Meeting Point / Meeting Hint** (`supabase/migrations/20260724121700_meeting_point_schema.sql`
+ `20260724121800_meeting_point_rpc.sql`) — this is the first real
implementation; v1.11's SPEC §9.1 only wrote a forward-looking principle
("Meeting Point must work independent of whether `activity_location_id` is
locked"), no table/RPC existed yet.

1. New append-only table `activity_meeting_point_update`
   (`activity_id`/`updated_by`/`description`/`created_at`) — deliberately not
   a "latest value only" column. "Current meeting point" = `order by
   created_at desc limit 1` query, same non-materialized-state philosophy as
   `known_member_count`. **`created_at` defaults to `clock_timestamp()`, not
   the codebase's usual `now()`** — `now()` is frozen for the whole
   transaction in Postgres, which is invisible in production (each RPC call
   is its own transaction) but broke the "take the latest row" ordering
   inside a single pgTAP test file (everything in one `begin;...rollback;`).
   This was caught by the new pgTAP test, not by inspection.
2. `activity_member.meeting_hint` (nullable text, `CHECK (char_length(...)
   <= 30)`) — no separate table, one hint per person per activity, overwritten
   in place, no history needed.
3. `app_config` gained a 4th key: `meeting_point_update_cooldown_minutes`
   (default `2 minutes`) — the cooldown lookup itself queries
   `activity_meeting_point_update` directly (no extra state column), same
   pattern as `fn_get_config_interval` usage elsewhere.
4. Two new RPCs: `update_meeting_point(activity_id, description)` and
   `update_meeting_hint(activity_id, hint)`. Both require caller to be a
   `JOINED` activity member and `activity.status in ('MATCHED', 'ONGOING')`
   — deliberately *not* restricted to `MATCHED` only (spec explicitly wanted
   same-day edits during `ONGOING` to still work); `COMPLETED`/`CANCELLED`
   reject with `ACTIVITY_NOT_ACTIVE`. `update_meeting_point` additionally
   enforces the cooldown and fires a new `MEETING_POINT_UPDATED` notification
   event to every `JOINED` member on success.
5. New Dart wrappers in `lib/rpc/activity_rpc.dart`
   (`updateMeetingPoint`/`updateMeetingHint`); `api_exception.dart` gained
   `activityNotActive`/`meetingPointUpdateCooldown`.

**Bug fix, discovered while writing this round's RLS pgTAP assertions, out of
scope of Meeting Point itself** (`supabase/migrations/20260724121900_fix_activity_member_rls_recursion.sql`):
`activity_member`'s own SELECT RLS policy
(`20260724120000_init.sql`) queries `activity_member` from inside its own
`USING` clause — Postgres treats that as genuine infinite recursion and
throws `infinite recursion detected in policy for relation
"activity_member"`, not a performance issue, a hard error. Verified directly
via `psql` that this breaks **any** `authenticated`-role query against
`activity` too (its own SELECT policy joins `activity_member`, so the
recursion propagates transitively) — meaning API.md 6.1's `GET activity` /
`GET activity_member` PostgREST endpoints have been silently 500ing for any
real client this whole time. Never caught before because every pgTAP test
prior to this round only queried these two tables via the `postgres`
superuser connection (which bypasses RLS entirely) or through
`SECURITY DEFINER` RPCs (which run as the function owner, also bypassing the
caller's RLS). Fixed with a `SECURITY DEFINER` helper
(`fn_is_activity_member(activity_id, user_id)`, same pattern as
`fn_get_config_interval`) so the inner existence check runs as the function
owner and doesn't re-trigger the caller's policy.

## Line B update: Activity Location voting wired up to Flutter

`propose_activity_location`/`vote_activity_location` and their two backing
tables shipped in the v1.11 round, but had zero Dart wrapper or client-side
verification — every other RPC in this repo has a `flutter test` run
attached to it (see the run logs in this file's git history and in the repo
root README), this pair didn't.

1. Ran `supadart` regen against the live local instance — picked up
   `activity_location_option.dart`/`activity_location_vote.dart` (already
   existed from the v1.11 backend round, now re-verified current) plus
   whatever else had drifted since (this round's Meeting Point tables/column/
   enum value — supadart regenerates the whole schema in one pass, there's
   no way to scope it to just two tables).
2. `proposeActivityLocation`/`voteActivityLocation` wrappers in
   `lib/rpc/activity_rpc.dart` already existed (written in the v1.11 round
   alongside the backend, just never exercised against a live instance)
   — verified their signatures still match the current RPC params.
3. New `test/activity_location_voting_smoke_test.dart`: two independently
   authenticated users, real `create_request`/`submit_request` calls, a real
   merge into a `MATCHED` activity, real `propose_activity_location`/
   `vote_activity_location` calls, a tally verified via a real authenticated
   `client.from('activity_location_vote')` read (not computed client-side),
   and a real `fn_start_activities()` lock verification. See the file's
   header comment for why it routes around two things: `fn_run_matching_engine`/
   `fn_start_activities` have no client RPC (triggered via `docker exec psql`,
   same escape hatch `rpc_smoke_test.dart` already uses for fixture seeding),
   and why it avoids the `<=2`-person merge branch entirely (see next section).

### Bug found while building the smoke test — since fixed

**Status: FIXED** in `supabase/migrations/20260724122000_fix_commit_match_pc1.sql`,
covered by the new `supabase/tests/database/08_pc1_activity_creation.test.sql`
(8 pgTAP assertions) and by `test/activity_location_voting_smoke_test.dart`,
which now exercises this exact path for real instead of routing around it
(see below).

Original finding, verified directly against the local instance (raw SQL,
reproduced twice): **a 2-person match could never actually produce an
`Activity`, even when both sides confirmed**. `commit_match(request_a_id,
request_b_id)` decided its branch by re-querying `count(*) from
request_member` for each request at call time. The `PENDING_CONFIRMATION`
flow (SPEC §12.1.2) calls `commit_match` a *second* time from
`respond_pending_confirmation` once both sides have confirmed — but the two
requests' `request_member` counts haven't changed since the first call, so
`v_total` was still `<= 2`, and `commit_match` took the `else` branch again:
it inserted *another* `pending_confirmation` row instead of creating an
`Activity`. The first `pending_confirmation` row did correctly end up
`status = 'CONFIRMED'`, but no `Activity` was ever created and
`match_request.status` never advanced past `PENDING_CONFIRMATION`. This
meant the entire "≤2-person activity" path — the exact scenario
`PENDING_CONFIRMATION` was built for (SPEC §12.1) — had probably never
actually produced a real Activity via the real RPC flow. No existing pgTAP
test caught this: `02_app_config_behavior.test.sql` only exercised the
`confirm=false` branch of `respond_pending_confirmation`; nothing called it
with `confirm=true` on both sides and checked for a resulting `Activity` row.

**Fix**: extracted the "unconditionally merge two requests into one new
Activity" logic (previously `commit_match`'s `v_total > 2` branch, verbatim)
into a new function `fn_create_activity_from_requests(request_a_id,
request_b_id)`. `commit_match` (used only by `fn_run_matching_engine`'s first
pairing attempt) now calls it for the `>2` branch; the `<=2` branch is
unchanged. `respond_pending_confirmation`'s PC1 transition (both sides
`CONFIRMED`) no longer calls `commit_match` at all — it calls
`fn_create_activity_from_requests` directly, since at that point there is
nothing left to decide: a `pending_confirmation` already exists and both
parties agreed, so the only correct action is to create the Activity
unconditionally. This was chosen over adding a `p_skip_pending_check`
boolean parameter to `commit_match` because the two call sites have
genuinely different preconditions (first-pairing-decides-branch vs.
already-decided-just-create), and a boolean flag would leave `commit_match`
with two contradictory implied contracts depending on who calls it and
whether they remember to pass the flag.

**Regression check baked into the fix**: `08_pc1_activity_creation.test.sql`
asserts there is still exactly 1 `pending_confirmation` row for the pair
after both sides confirm (the original bug's direct symptom — a second row
appearing was the signature of the failure), plus that an `Activity`
containing both users actually exists and both `match_request` rows reach
`MATCHED`. `activity_location_voting_smoke_test.dart` was rewritten to drop
its member-padding workaround entirely and now drives the real 2-person
`PENDING_CONFIRMATION` → both-confirm → `Activity` path end to end, including
a live `docker exec psql` count check that only one `pending_confirmation`
row exists for the pair after both confirm.

## v1.12 update: all eight §9 background jobs now exist as callable functions

First systematic audit of API.md §9's background-job table's actual
implementation status (previously tracked piecemeal across several rounds).
Findings before this round: `fn_run_matching_engine`/
`fn_cleanup_pending_confirmations`/`fn_start_activities`/
`fn_remind_missing_location_candidates` already existed; "Request 過期"
(R4 + Downgrade creation), "Downgrade 超時", "Activity 超時完成" (A4), and
"結束提醒" had **zero** corresponding function — only the §9 table's prose
description. Additionally, two existing functions had a documented
notification event type that was never actually inserted anywhere:
`respond_downgrade` never sent `DOWNGRADE_RESULT`, and
`fn_cleanup_pending_confirmations` never sent the "配對未成立" notification
its own PC2 row description already promised.

All fixed in `supabase/migrations/20260724122100_background_jobs_enum.sql` +
`20260724122200_background_jobs_rpc.sql`:

1. **`fn_expire_requests()`** (new) — R4 + Downgrade creation. `target_size`
   algorithm: `greatest(2, current real JOINED headcount)`, not a fixed
   number — asks the group to accept exactly who's actually there rather
   than an arbitrary target; the DB's existing `target_size >= 2` CHECK and
   the "must be below original `min_participants`" app-layer rule (ERD note
   21) both fall out of this naturally, no extra special-casing needed. Time
   window check reinterprets SPEC §8's "remaining time before deadline"
   (written for a scheduler that runs *before* the deadline) as "how long
   *since* the deadline passed" (`now() - latest_start <
   downgrade_consent_window_minutes`), since this function's scan condition
   is `latest_start < now()` — deadline already past. A request only ever
   gets offered a downgrade once (gated on "does any `downgrade_request` row
   already exist for this `request_id`", any status) — never re-offered
   after a `REJECTED`/`TIMEOUT`. Deliberately leaves alone the edge case
   where a solo `REQUESTING` request's real headcount already reached
   `min_participants` (via invite-link joins) but `fn_run_matching_engine`
   never found a second request to merge with — R4's own condition is
   "still hasn't reached `min_participants`", so this case isn't R4 at all;
   no code path currently turns such a row into an Activity by itself, and
   this round doesn't add one (see ERD note 39).
2. **`fn_expire_downgrades()`** (new) — Downgrade 超時. `PENDING` +
   `expire_at < now()` → `TIMEOUT`; deliberately does **not** touch
   `match_request.status` (Downgrade never leaves the request in anything
   but `REQUESTING`, per STATE_MACHINE.md's existing "Downgrade 子流程"
   section — this was already documented, just never had code behind it
   until now).
3. **`respond_downgrade`** — added the previously-missing `DOWNGRADE_RESULT`
   notification: sent immediately on any `DISAGREE` (`status=REJECTED`),
   and only at the moment all parties `AGREE` (`status=APPROVED`) — not on
   each partial agreement, mirroring `respond_pending_confirmation`'s
   existing pattern of only notifying at the final PC1/PC2 transition.
4. **`fn_complete_activities()`** (new) — Activity 超時完成 (A4). No quorum
   recomputation needed: `submit_completion_report` already flips `status`
   to `COMPLETED` synchronously in the same transaction the moment it hits
   quorum (`20260724120600_rpc_completion_and_settlement.sql`), so any row
   still `status='ONGOING'` here is guaranteed to not have reached quorum —
   the two paths are mutually exclusive by construction, not by an extra
   check. Silent fallback: no No-show judgment, no reliability events, no
   notification.
5. **`fn_remind_completions()`** (new) — 結束提醒. Dedup mirrors
   `fn_remind_missing_location_candidates`'s existing pattern exactly: query
   `notification` itself for an existing `COMPLETE_CONFIRMATION` row for
   that activity, no extra column.
6. **`fn_cleanup_pending_confirmations`** — added the previously-missing
   "配對未成立" notification, new event type `MATCH_NOT_FORMED`. Same
   non-attribution principle as ERD note 16: payload carries only the
   recipient's *own* `request_id`, nothing about the other party or why it
   failed (declined vs. timed out).

**Deliberately not addressed this round** (flagged, not fixed): once a
`downgrade_request` reaches `APPROVED`, SPEC §8 / STATE_MACHINE.md both say
"Matching Engine 以 `target_size` 重新撮合" — no code anywhere actually
reads `target_size` to re-run matching at a lower threshold.
`respond_downgrade`'s own comment already acknowledged this gap before this
round; this round is simply the first time `APPROVED` can actually be
produced end-to-end (since nothing created `downgrade_request` rows before),
which makes the gap reachable for the first time rather than purely
theoretical. Left for a future round (see ERD note 39, SPEC.md v1.12
changelog #9).

Consistent with every other background job in this file: these four new
functions are callable functions only, not scheduled via `pg_cron` — that
remains a separate, deliberately deferred task.

## v1.13 update: new "activity starting soon" reminder job, configurable multi-point lead time

New migrations `20260724122300_activity_upcoming_enum.sql` +
`20260724122400_activity_upcoming_rpc.sql`:

1. **New notification event type `ACTIVITY_UPCOMING`** — deliberately kept
   separate from the existing `ACTIVITY_REMINDER` (activity has *already*
   started, sent by `fn_start_activities()` at the A2 transition). Same
   underlying signal (an activity's `start_time` matters) but opposite timing
   and different copy, so they don't share an event type.
2. **`app_config.activity_reminder_lead_minutes_list`** — the first
   `app_config` key that needs to hold *multiple* values (default `{30,10}`:
   remind 30 minutes before start, and again 10 minutes before), unlike every
   other existing key (`cooldown_minutes`, `confirm_window_minutes`,
   `downgrade_consent_window_minutes`, `location_reminder_lead_minutes`),
   which are all single scalars. Stored as a Postgres array literal
   (`'{30,10}'`) rather than a comma-separated string, jsonb array, or split
   across multiple keys (`activity_reminder_lead_1`/`_2`) — a literal casts
   directly via `value::int[]` in a new `fn_get_config_int_array(p_key)`
   helper, exactly mirroring the existing `fn_get_config_interval`'s
   `value::interval` one-liner. No `string_to_array` step, no jsonb parsing,
   no ad-hoc key-naming convention to maintain.
3. **`fn_remind_upcoming_activities()`** (new) — scans `status='MATCHED'`
   activities whose `start_time` falls within any configured lead point,
   sends `ACTIVITY_UPCOMING` to every `JOINED` member with `lead_minutes` in
   the payload so the client can render "starts in {lead_minutes} minutes".
   Dedup mirrors `fn_remind_missing_location_candidates`'s existing pattern
   (query `notification` itself, no extra column) but keyed on
   `(activity_id, lead_minutes)` instead of just `activity_id`, since the
   30-minute and 10-minute reminders for the same activity are two distinct
   notifications that must each be able to fire independently.
4. **Copy documented for the first time** (API.md §8.4) — no notification
   event type in this repo had its title/body text formally recorded before
   this round:
   - `ACTIVITY_UPCOMING`: title "活動快開始了", body "還有 {lead_minutes} 分鐘，記得看一下活動地點跟集合地點"
   - `ACTIVITY_REMINDER` (unchanged behavior, copy recorded for the first time): title "活動開始了", body "時間到囉，記得看一下活動地點跟集合地點再出發"

Same as every other background job: callable function only, not scheduled
via `pg_cron`.

## v1.14 update: account deletion (Apple/Google App Store hard requirement)

New migrations `20260724122500_delete_account_schema.sql` +
`20260724122600_delete_account_guard.sql` +
`20260724122700_delete_account_rpc.sql`, plus a new Edge Function
`supabase/functions/delete-auth-user/`:

1. **Architecture decision, backed by real research, not assumption**:
   confirmed via Supabase's own docs that deleting `auth.users` correctly
   (cleaning up GoTrue-internal sessions/refresh_tokens/identities) has no
   self-service client endpoint — only the Admin API
   (`auth.admin.deleteUser`), which requires a `service_role`/`supabase_admin`
   JWT. That key can never live in the Flutter client, so this is the one
   piece of the whole feature that genuinely cannot stay a plain SQL RPC. A
   thin Edge Function is the exception; every other piece is a SQL RPC as
   usual.
2. **`app_user` row is kept and de-identified in place, never actually
   `DELETE`d** — discovered `app_user.id references auth.users(id) on
   delete cascade` in the init migration, which means a real row delete
   (whether triggered directly or via the auth.users cascade) would
   immediately hit FK violations on 13 child tables that have no `on delete
   cascade` (`match_request.owner_id`, `activity_member.user_id`, etc.).
   Clearing those child rows first was rejected too — it would corrupt other
   users' reliability counts, vote tallies, and meeting-point history. Kept
   row + unchanged `id` + scrubbed identity columns sidesteps the FK problem
   entirely and preserves every other user's data integrity, at the cost of
   one new nullable `app_user.deleted_at` column.
3. **21 RPCs re-`create or replace`d in one migration** to add an
   `ACCOUNT_DELETED` guard right after each one's existing `UNAUTHORIZED`
   check: `complete_profile`, `get_my_reliability`, `propose_activity_type`,
   `create_request`, `submit_request`, `cancel_request`,
   `get_or_create_invite_link`, `join_request_by_token`,
   `revoke_invite_link`, `get_activity_contacts`,
   `cancel_activity_participation`, `get_pending_confirmation_status`,
   `respond_pending_confirmation`, `submit_completion_report`,
   `rematch_vote`, `leave_request`, `propose_location`,
   `propose_activity_location`, `vote_activity_location`,
   `update_meeting_point`, `update_meeting_hint`, `respond_downgrade`.
   Excluded: `search_activity_type` (doesn't use `auth.uid()` at all — pure
   public search) and every `fn_*` background job / internal helper (no
   caller identity to check). `complete_profile` is the one non-obvious
   inclusion: it's the onboarding entry point, but it's also an `upsert`
   (`on conflict (id) do update`) — without the guard, a still-valid
   residual access token from a just-deleted account could call it again and
   overwrite the scrubbed fields back to real data, silently "undeleting"
   the account.
4. **`delete_account()` RPC** — idempotent (`deleted_at is not null` is a
   no-op returning `{success: true, already_deleted: true}`), doesn't gate on
   `suspended_until` (deletion is a right, not something a punitive status
   should be able to block). De-identifies `app_user` (email becomes
   `'deleted+' || id`, which also required loosening the two existing email
   CHECK constraints with a `deleted_at is not null or ...` escape hatch —
   they can't be altered in place, only dropped and re-added).
   `degree_level`/`school` are deliberately left untouched (coarse
   categories, not individually identifying once name/photo/contacts are
   gone). Auto-cancels/leaves any still-open `match_request` and
   `activity_member` the caller is part of so other members aren't left
   waiting on a ghost; deliberately does **not** write a
   `user_reliability_event` or trigger the cooldown for the activity-member
   case — leaving the platform isn't a no-show. Hard-deletes the caller's own
   `notification` inbox and any `match_history_avoidance` rows involving
   them (both are either purely private or permanently useless once the
   account can never re-enter the matching pool). Every other child table
   (`activity_location_option`/`vote`, `activity_meeting_point_update`,
   `downgrade_consent`, `completion_report`, `user_reliability_event`,
   `rematch_vote`, `activity_type`/`location.created_by`) is left completely
   untouched — confirmed by reading `fn_reliability_tier`/`fn_is_new_user`
   that reliability is purely self-referential (`where user_id =
   p_user_id`), so there is no cross-user data-integrity risk from leaving a
   deleted user's historical rows in place.
5. **Idempotency, verified against the real local instance, not assumed**:
   `auth.admin.deleteUser(id, true)` itself is confirmed idempotent (GoTrue's
   `internal/api/admin.go` early-returns on an already-`DeletedAt` user). But
   the Edge Function resolves the caller's identity first via
   `supabaseAdmin.auth.getUser(jwt)`, and a real test against a running local
   instance showed that call returns 401 once the account is already
   soft-deleted — even with the same still-valid access token. So a repeat
   call to `delete-auth-user` isn't "200 both times", it's "200 then 401
   forever after". The Flutter-side retry loop (`account_deletion.dart`,
   2 retries with 1s/3s backoff) handles this correctly regardless, since it
   only exists to cover a transient failure on the *first* successful
   attempt and unconditionally signs out locally either way — documented
   here so nobody "fixes" the 401 into a false idempotency guarantee later.
6. `shouldSoftDelete` is passed explicitly as `true` — both the Go source
   and the JS client docs confirm it defaults to `false` ("backward
   compatibility"), which would hard-delete `auth.users` and trigger the
   cascade from point 2.

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
- `respond_pending_confirmation`'s atomic per-caller-field update + PC1/PC2 transition logic matches §4.2's description exactly, including the 30-minute cooldown write on `confirm=false` (via `fn_get_config_interval('cooldown_minutes')`) and PC1's Activity-creation call — as of `20260724122000_fix_commit_match_pc1.sql`, PC1 calls `fn_create_activity_from_requests(...)` directly rather than `commit_match(...)` (see the "Bug found while building the smoke test" section above for why).
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
