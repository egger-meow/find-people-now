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

## v1.14.1 update: closed out the 11-code doc↔code discrepancy from the general proofreading pass

Full round-trip resolution of both discrepancy tables below (`Error codes
documented in API.md but never raised` and `Error codes raised in practice
but not documented`), verified against `supabase test db` (141 assertions,
14 files, all green) after a `supabase db reset`. Scope was explicitly bounded
to doc↔code alignment, no product decisions — see SPEC.md's v1.14.1 changelog
entry for the user-facing summary.

1. **Two real implementation gaps fixed**, both in
   `20260724122800_fix_activity_validation_gaps.sql`, both new
   `create or replace` on top of `20260724122600_delete_account_guard.sql`'s
   versions (so the `ACCOUNT_DELETED` guard stays intact):
   - `cancel_activity_participation` gained an `ACTIVITY_NOT_ACTIVE` check
     (`activity.status not in ('MATCHED', 'ONGOING')`) — reused the existing
     code from 6.6/6.7 rather than implementing the never-raised
     `ACTIVITY_ALREADY_ENDED`, since the underlying condition is identical.
   - `submit_completion_report` gained two checks: `activity.status = 'ONGOING'`
     (else `ACTIVITY_NOT_ENDED`) and an `absent_user_ids` membership check
     (else `INVALID_ABSENT_TARGET`). The `ONGOING`-only gate has a useful side
     effect: it closes a latent duplicate-settlement bug where a report
     arriving after the activity had already flipped to `COMPLETED` would
     re-run the full settlement loop and double-insert `user_reliability_event`
     rows for every member (the loop has no "already settled" guard of its
     own — see `20260724120600_rpc_completion_and_settlement.sql`).
   - Both covered by new `supabase/tests/database/14_activity_validation_gaps.test.sql`
     (9 pgTAP assertions: the two new `ACTIVITY_NOT_ACTIVE` sites, the three
     `ACTIVITY_NOT_ENDED` sites — not-started/`COMPLETED`/`CANCELLED` — the
     `INVALID_ABSENT_TARGET` site plus a no-leftover-row check, and a
     regression check that a legitimate `ONGOING` submission with a real
     member id still succeeds).
2. **Six doc-only fixes** (see the two discrepancy tables below for the
   per-code detail): `INVITE_LINK_REVOKED`, `INVALID_PENDING_CONFIRMATION`,
   `CONTACT_EXPIRED` removed from API.md (existing alternative behavior was
   already correct design, just undocumented); `INVALID_INPUT` (multiple
   sites), `INVALID_MIN_PARTICIPANTS`/`INVALID_MAX_PARTICIPANTS`, `FORBIDDEN`
   (detail `NOT_PARTY_TO_CONFIRMATION`) added to API.md where they were
   missing.
3. **`NAME_BLACKLISTED` deliberately left untouched** — flagged in the v1.10
   update section above as an already-known, already-deferred gap; the user
   explicitly reconfirmed keeping it out of scope for this round rather than
   letting a general cleanup pass quietly absorb it.
4. **API.md's stale ERD.md version reference fixed**: line 2 had said "建立在
   ERD.md v1.7 之上" since some early round and was never updated in step with
   ERD.md's own header bumps (last actually at v1.14) — same class of drift
   this file exists to catch, just in the other direction (a *citation*
   going stale, not a behavior). Now reads v1.14 for both ERD.md and
   STATE_MACHINE.md, matching their current headers.
5. `lib/rpc/api_exception.dart` gained `activityNotEnded`/`invalidAbsentTarget`
   entries (per that file's own rule: add a code only once a migration
   actually raises it — both now do).

## v1.17 update: user-initiated blocking

New migrations `20260724124100_user_block_schema.sql` +
`20260724124200_user_block_rpc.sql` + `20260724124300_matching_engine_user_block_check.sql`:

1. **New table `user_block`** (`blocker_id`/`blocked_id`/`reason`/`created_at`,
   `unique(blocker_id, blocked_id)`, `check (blocker_id <> blocked_id)`) —
   deliberately not the same table as `match_history_avoidance`: that one is
   system-written, 7-day-expiring, and normalized into a directionless pair
   (`user_a_id < user_b_id`); this one is user-initiated, permanent, and
   directional (A blocking B says nothing about B blocking A), and only the
   blocker can undo it. See ERD.md design note 43 for the full reasoning.
2. **`block_user(p_blocked_id, p_reason?)` / `unblock_user(p_blocked_id)`** —
   both idempotent. `block_user` rejects self-block (`INVALID_INPUT` detail
   `CANNOT_BLOCK_SELF`) and a nonexistent target (`NOT_FOUND` detail
   `BLOCKED_USER_NOT_FOUND`); repeat calls just overwrite `reason` via
   `on conflict do update`, no second row. Neither checks `suspended_until` —
   blocking is a self-protection action, not a privilege a suspended user
   should lose. Both wrapped in new `lib/rpc/user_block_rpc.dart`.
3. **`fn_run_matching_engine` gained an independent `user_block` check**,
   added right after the existing `match_history_avoidance` check inside the
   candidate-scan loop — deliberately separate code, not merged into the
   avoidance check, since the two have different semantics (see point 1).
   Checks both directions (`(blocker=a and blocked=b) or (blocker=b and
   blocked=a)`) since `user_block` isn't normalized like avoidance is.
4. **RLS**: `own_blocks_select` policy (`blocker_id = auth.uid()`) + `grant
   select on user_block to authenticated` (inline in the schema migration,
   same pattern as `activity_meeting_point_update`'s grant — not appended to
   the historical `20260724120800_grants.sql`). Listing is plain PostgREST
   (`GET user_block?blocker_id=eq.<self>`), no dedicated RPC. The blocked
   party has no select policy at all — same "RLS enabled, no policy for the
   other side" pattern as `pending_confirmation`, but here only one side
   (blocked) is excluded, not both.
5. **New `supabase/tests/database/16_user_block.test.sql`** (10 pgTAP
   assertions): block prevents matching, unblock restores it, idempotent
   repeat-block, self-block/nonexistent-target rejection, and RLS (blocker
   sees own block, blocked party never does). Note for anyone writing a
   similar RLS test: switching to `set local role authenticated` mid-test
   loses access to a `create temp table` fixture unless you `grant select on
   fixtures to authenticated` first (temp tables aren't owned by/auto-granted
   to that role) — same fix already documented inline in
   `05_propose_location.test.sql`, easy to forget when writing a new file
   from scratch.
6. `supadart` regen picked up `lib/generated/user_block.dart` (new table);
   no other generated file changed content-wise (`supadart_exports.dart`/
   `supadart_header.dart` diffs are just the new table being registered).

## v1.18 update: report mechanism

New migrations `20260724124400_report_schema.sql` +
`20260724124500_report_rpc.sql`:

1. **New table `report`** (`reporter_id`/`reported_user_id`/
   `reported_activity_id`/`category`/`detail`/`status`/`created_at`) — target
   is a user and/or an activity (`check (reported_user_id is not null or
   reported_activity_id is not null)`). New enums `report_category`
   (`SPAM`/`HARASSMENT`/`OTHER`) and `report_status` (`PENDING`/`REVIEWED`).
2. **`submit_report(category, reported_user_id?, reported_activity_id?,
   detail?)`** — both targets missing raises `INVALID_INPUT` detail
   `REPORT_TARGET_REQUIRED` (checked in the RPC before the DB CHECK would
   catch it, for a clearer error code). Wrapped in new
   `lib/rpc/report_rpc.dart`.
3. **No admin API/UI added** — same pattern as the `pending_review` view
   (v1.10): review happens by hand in Supabase Studio querying
   `status='PENDING'`; a human can then manually update the target's
   existing `app_user.suspended_until` if warranted. No new punishment
   mechanism, no dedicated view either (unlike `pending_review`, `report` is
   a single table — querying `status='PENDING'` directly is enough, no UNION
   needed).
4. **RLS**: `own_reports_select` (`reporter_id = auth.uid()`) + `grant select
   on report to authenticated`, inline in the schema migration (same
   pattern as `user_block`). No insert/update grant — writes go through
   `submit_report`; status review is a `service_role`/Studio operation.
5. **New `supabase/tests/database/17_report.test.sql`** (7 pgTAP assertions):
   reporting a user, reporting an activity, `REPORT_TARGET_REQUIRED` when
   both targets are missing, and RLS (reporter sees own reports, other users
   don't).
6. `supadart.yaml` gained `report_category`/`report_status` enum entries;
   regen picked up `lib/generated/report.dart` (new table).

## v1.20 update: `app_user.onboarding_seen_at`

New migration `20260724124600_onboarding_seen_at.sql`: adds nullable
`app_user.onboarding_seen_at timestamptz`. No new RPC — the existing `grant
select, update on app_user to authenticated` + `own_profile_update` RLS
policy (`id = auth.uid()`) already cover a plain `PATCH app_user` write, so
the client can set this directly via `client.from('app_user').update(...)`.
`docs/UI_PLAN.md` §11.1 already specified this design (onboarding card shown
once when this column is null) before the column existed — this migration
just makes that design implementable. `supadart` regen picked up the new
field on `lib/generated/app_user.dart` (`onboardingSeenAt`); no other
generated file changed content-wise.

## v1.21 update: NYCU seniority reminder

New migration `20260724124700_seniority_reminder_rpc.sql`:

1. **`fn_parse_nycu_enrollment_year(email)`** (plain `language sql`, not
   plpgsql) — returns the ROC enrollment year parsed from the last two
   characters of the email's local-part (`mg09` → 109, `cs15` → 115,
   regardless of prefix length), or `null` if those two characters aren't
   both digits. Written as a plain SQL function specifically so pgTAP can
   call it directly without simulating `auth.uid()`.
2. **`fn_seniority_reminder_needed(email, degree_level)`** — `false`
   immediately for any non-`@nycu.edu.tw` domain (including `@nthu.edu.tw`)
   or an unparseable email; otherwise compares `(current ROC year - enrolled
   ROC year) > threshold`, threshold = 6/4/7 for `UNDERGRAD`/`MASTER`/`PHD`.
   Strictly `>`, not `>=` — exactly-at-threshold does not trigger.
3. **`check_enrollment_reminder(p_degree_level)`** (the only actual RPC) —
   thin wrapper: resolves the caller's email from `auth.users` via
   `auth.uid()`, then calls point 2's helper. Deliberately has no
   `ACCOUNT_DELETED`/`suspended_until` guard — called during registration,
   before an `app_user` row necessarily exists, so neither check is
   meaningful at that point. Wrapped as `checkEnrollmentReminder()` in
   `lib/rpc/auth_profile_rpc.dart`, meant to be called right before
   `completeProfile()` during the registration flow (see
   `docs/UI_PLAN.md` §12).
4. **No new column, no persisted result** — email (enrollment year),
   `degree_level`, and current date are all already available; this is
   computed once at registration time, same "query instead of cache"
   philosophy as `known_member_count`/vote tallies (see ERD design note 45).
5. **New `supabase/tests/database/18_seniority_reminder.test.sql`** (9
   pgTAP assertions) — deliberately builds test emails *dynamically* from
   `extract(year from now())::int - 1911` rather than hardcoding a specific
   ROC year, so the test doesn't silently start failing/passing for the
   wrong reason as real time passes. Covers over-threshold (true) and
   exactly-at-threshold (false) for all three degree levels, non-NYCU
   domain skip, unparseable-format skip, and one real `set_config`-simulated
   end-to-end call through the `check_enrollment_reminder` RPC.

## v1.22 update: `get_pending_confirmation_candidate_info` — SPEC §12.1.3 "安全資訊卡" had no backing RPC

Found while scoping "我的活動" round 1 (not a pgcrypto/search_path-style
"implemented but never exercised" bug — this one genuinely didn't exist).
SPEC.md §12.1.3 (defined back in v1.4) requires a "安全資訊卡" for
`PENDING_CONFIRMATION`: the other party's `display_name`/`avatar_url`/
`school`/`department`/`degree_level`/Reliability tier/completed activity
count. `get_pending_confirmation_status` (§4.1) only ever returned
`{ pending_confirmation_id, status, confirm_window_expire_at }`, and
`pending_confirmation` itself has RLS enabled with no SELECT policy at all
(ERD design note 16) — there was no path to this data.

New migration `20260724125600_pending_confirmation_candidate_info.sql` adds
**`get_pending_confirmation_candidate_info(pending_confirmation_id)`**
(`SECURITY DEFINER`), wrapped as `getPendingConfirmationCandidateInfo()` in
`lib/rpc/confirmation_rpc.dart`:

1. Same authorization as `respond_pending_confirmation` (§4.2) — caller must
   own `request_a` or `request_b`, else `FORBIDDEN` detail
   `NOT_PARTY_TO_CONFIRMATION`; unknown id → `NOT_FOUND` detail
   `PENDING_CONFIRMATION_NOT_FOUND` (same codes as 4.1/4.2).
2. Returns the **other** party's info — verified symmetric against a real
   local instance before writing any pgTAP (see the RLS/manual-probe note
   below): party A's call returns party B's profile and vice versa.
3. Reuses existing helpers for the derived fields — `fn_reliability_tier`
   (already callable for any `user_id`, not just `auth.uid()`, same as
   `get_my_reliability` already relies on) and a direct `ATTENDED`-event
   count from `user_reliability_event`, same event type `fn_is_new_user`
   checks — no new "what counts as completed" definition invented.
4. Deliberately does **not** touch `user_a_response`/`user_b_response` — the
   §12.1.2 symmetric non-attribution guarantee 4.1 already provides is
   unaffected; this RPC only adds profile fields.
5. Verified twice against a real local `supabase start` instance before any
   test was written: first a manual `docker exec psql` probe (`set local
   role authenticated` + `set_config('request.jwt.claim.sub', ...)`, same
   technique as `05_propose_location.test.sql`/`19_waiting_room_realtime_rls.test.sql`)
   confirming both directions return the counterpart's real data and a
   stranger/bogus-id call raises the right codes, then formalized as
   `supabase/tests/database/21_pending_confirmation_candidate_info.test.sql`
   (9 pgTAP assertions). `supabase test db` passes clean (21 files, 197
   assertions, no regressions).

## v1.23 update: `get_activity_member_profiles` — UI_PLAN §4.1 Tab 2 member list had no source for school/department/degree_level/reliability tier

Found while scoping "我的活動" round 3 (same class of gap as v1.22, not a
pgcrypto/search_path-style latent bug — this genuinely never existed).
UI_PLAN.md §4.1 Tab 2 requires the member list to show 頭像/顯示名稱/學制/
科系/可信度等級 for every member. `get_activity_contacts` (§6.2) returns
`display_name`/`avatar_url`/`role`/`contacts` for every member
unconditionally — but never `school`/`department`/`degree_level`/reliability
tier. `app_user`'s `own_profile_select` RLS (`id = auth.uid()`) blocks a
direct PostgREST read of another member's row, so there was no path to this
data at all.

New migration `20260724125700_activity_member_profiles.sql` adds
**`get_activity_member_profiles(activity_id)`** (`SECURITY DEFINER`), wrapped
as `getActivityMemberProfiles()` in `lib/rpc/activity_rpc.dart`:

1. Same authorization as `get_activity_contacts` (§6.2) — caller must be a
   `JOINED` member of the activity, else `NOT_ACTIVITY_MEMBER`; unknown
   activity id → `NOT_FOUND` detail `ACTIVITY_NOT_FOUND`.
2. Returns **every** member regardless of `status` (`JOINED`/`CANCELLED`),
   matching `get_activity_contacts`'s no-filter behavior — the two RPCs'
   member sets always stay in sync, no risk of one showing a member the
   other omits.
3. Reuses `fn_reliability_tier(user_id)` — same helper `get_my_reliability`
   and v1.22's `get_pending_confirmation_candidate_info` already call for an
   arbitrary `user_id`, no new definition invented.
4. Deliberately does **not** repeat `display_name`/`avatar_url`/`contacts` —
   `get_activity_contacts` already owns those unconditionally; the client
   merges both RPCs' results by `user_id` to build the full roster. Kept the
   new RPC's blast radius to exactly the missing fields, same principle as
   v1.22's addition.
5. Verified twice against a real local `supabase start` instance before any
   test was written: first a manual `docker exec psql` probe (`set local
   role authenticated` + `set_config('request.jwt.claim.sub', ...)`, same
   technique as v1.22's probe) confirming a real JOINED member sees both
   members' real profile data and a stranger call raises
   `NOT_ACTIVITY_MEMBER`, then formalized as
   `supabase/tests/database/22_activity_member_profiles.test.sql` (8 pgTAP
   assertions, including a CANCELLED-member-still-listed case and a
   field-non-duplication check). `supabase test db` passes clean (22 files,
   205 assertions, no regressions).

## v1.24 update: `mark_arrived` — Arrival Check「我到了」

New feature, not a doc/code gap. Migrations
`20260801100000_arrival_check_schema.sql` (adds `activity_member.arrived_at`
+ `notification_event_type = 'MEMBER_ARRIVED'`),
`20260801100100_arrival_check_rpc.sql` (**`mark_arrived(activity_id)`**,
`SECURITY DEFINER`), `20260801100200_realtime_activity_member.sql` (adds
`activity_member` to the `supabase_realtime` publication — it had been
deliberately excluded, see the provider comment below).

1. Same gate as `update_meeting_hint`/`update_meeting_point` (§6.6/6.7):
   caller must be a `JOINED` member, activity `status in (MATCHED, ONGOING)`,
   else `NOT_ACTIVITY_MEMBER`/`ACTIVITY_NOT_ACTIVE`.
2. One-directional: `arrived_at` only ever moves `null → now()`, no RPC path
   clears it back to `null`.
3. Idempotent by design, not by accident: a second call from an
   already-arrived member returns the existing row and does **not** insert
   another `notification` row — verified by pgTAP (see below), since a
   naive `update ... returning` would silently re-fire the notification
   insert on every repeat call otherwise.
4. Notification recipients are the activity's JOINED members **excluding
   the arriver** — deliberately not copying `update_meeting_point`'s
   broadcast-to-everyone-including-self pattern; being told "you arrived"
   about yourself has no information value.
5. Wrapped as `markArrived()` in `lib/rpc/activity_rpc.dart`. Client-side,
   `activity_detail_providers.dart` adds a narrow
   `activityArrivalStreamProvider` (`user_id`/`arrived_at` only) rather than
   converting the whole member roster (`activityMemberRosterProvider`) to a
   `StreamProvider` — that provider's own comment explains why it's a plain
   `FutureProvider` (no realtime need previously); arrival status is the
   first roster-adjacent field that genuinely needs realtime, so it's
   layered on top instead of changing the existing provider's shape.
6. Covered by `supabase/tests/database/24_arrival_check.test.sql` (11 pgTAP
   assertions: NOT_ACTIVITY_MEMBER, successful mark, correct-recipient
   notification, self-exclusion, idempotency/no-duplicate-notification,
   reverse-direction notification, COMPLETED/CANCELLED boundaries,
   ACTIVITY_NOT_FOUND, ACCOUNT_DELETED — see the v1.29.1 update below for the
   race-condition fix in the underlying RPC).

## v1.25 update: `submit_feedback` + `send-feedback-email` Edge Function — filled the long-standing 〔聯絡信箱待補〕 placeholder

New feature. Migrations `20260801110000_feedback_schema.sql` (new
`feedback` table, RLS mirrors `report`'s own-write/own-read shape) and
`20260801110100_feedback_rpc.sql` (**`submit_feedback(message,
activity_id?, app_version?, device_info?)`**, `SECURITY DEFINER`).

1. `feedback_screen.dart` was a pure static FAQ page with a literal
   `〔聯絡信箱待補〕` placeholder where a contact email should go — this
   round replaces that with an actual submission form instead of just
   filling in an address.
2. Two-step client flow, deliberately not one atomic operation:
   `submitFeedback()` (RPC, durable — the `feedback` row is the only
   guaranteed-persistent artifact) then best-effort
   `sendFeedbackEmail()` (`client.functions.invoke('send-feedback-email')`).
   The email step's failure is swallowed and never surfaces to the user —
   same non-blocking pattern as `account_deletion.dart`'s
   `_invokeDeleteAuthUserWithRetry` treats its Edge Function call.
3. New Edge Function `supabase/functions/send-feedback-email/` — same
   "only place holding a secret key" shape as `delete-auth-user` (v1.14):
   `RESEND_API_KEY`/`FEEDBACK_EMAIL_TO`/optional `FEEDBACK_EMAIL_FROM` are
   Supabase secrets, never in `app/.env`. Takes only a `feedback_id`,
   re-reads the row server-side via service_role rather than trusting
   client-supplied email content, and checks the row's `user_id` matches
   the caller's JWT (blocks replaying someone else's `feedback_id` to
   trigger a resend).
4. Added `package_info_plus` dependency for `app_version` metadata;
   `device_info` deliberately uses `dart:io`'s `Platform.operatingSystem`
   instead of adding `device_info_plus` — good enough for support triage
   without a second, heavier platform-channel plugin.
5. `AppTextField` gained an optional `maxLines` parameter (default `1`,
   every existing call site unaffected) to support the feedback message's
   multi-line input — reused rather than duplicating a one-off `TextField`.
6. No pgTAP coverage for the Edge Function itself (Deno runtime, outside
   pgTAP's scope) — `submit_feedback`'s SQL-level behavior (auth, length
   validation, row shape) is covered by
   `supabase/tests/database/25_feedback.test.sql`.

## v1.26 update: `get_campus_pulse` — homepage "Campus Activity Pulse"

New feature. Migration `20260801120000_campus_pulse_rpc.sql` adds
**`get_campus_pulse(school, campus)`** (`SECURITY DEFINER`, returns
aggregate `(activity_type_id, activity_type_name, person_count)` rows).

1. Deliberately aggregate-only: `match_request`'s `my_requests_select` RLS
   policy is owner/member-scoped by design (the blind-matching boundary,
   SPEC §11) — this RPC never exposes an individual request's owner or
   timing, only a per-activity-type count of currently-`REQUESTING` rows.
2. Wrapped as `getCampusPulse()` in `lib/rpc/activity_type_rpc.dart`
   (returns a small `CampusPulseEntry` DTO, not a generated table class —
   the RPC returns a custom aggregate shape, not a `setof <table>`).
3. `lib/match/match_providers.dart`'s `campusPulseProvider` is a
   `StreamProvider.family` built from a 30s `Timer.periodic`, **not**
   Realtime — adding all of `match_request` to the `supabase_realtime`
   publication would leak individual add/remove event timing, a strictly
   finer-grained signal than the aggregate count this feature needs. See
   the migration and provider's own comments for the full reasoning.
4. UI: `_CampusPulseBanner` in `create_request_screen.dart`, reusing that
   file's existing private `_activityTypeIcon()` keyword-match helper
   rather than duplicating an icon table. Renders nothing (not an empty
   state) when the campus currently has zero `REQUESTING` requests.
5. Covered by `supabase/tests/database/26_campus_pulse.test.sql` — counts
   only `REQUESTING` (not `DRAFT`/`PENDING_CONFIRMATION`/`MATCHED`), scoped
   correctly per `(school, campus)`, zero-count types omitted entirely.

## v1.39 fix: `get_campus_pulse` counted Requests, not people

Bug found in production use: two independent solo requests for the same
activity type/campus (neither had found anyone yet) correctly showed "2",
but a *single* request that had already pulled in extra members via an
invite link (`request_member`) still only counted as 1 — the original query
did `count(*)` over `match_request` rows (i.e. counted "groups"), not actual
headcount. Migration `20260806000000_campus_pulse_headcount.sql` changes it
to `count(rm.*)` over `request_member` rows with `status = 'JOINED'`, joined
per matching `REQUESTING` request. The returned column was also renamed
`request_count` → `person_count` so the name can't mislead the same way
again. `lib/rpc/activity_type_rpc.dart`'s `CampusPulseEntry.requestCount` →
`.personCount`; UI label in `create_request_screen.dart` changed from
"N 組配對中" to "N 人在等" to match the headcount semantics. Test coverage
added to `26_campus_pulse.test.sql` (a request with 2 joined + 1 left
invited member must count as 3, not 1 or 4).

## v1.27 update: `subscribe_activity_alert`/`unsubscribe_activity_alert` — Alert Subscription

New feature. Migrations `20260801130000_alert_subscription_schema.sql`
(new `activity_alert_subscription` table + `notification_event_type =
'ALERT_TRIGGERED'`), `20260801130100_alert_subscription_rpc.sql`
(**`subscribe_activity_alert`**/**`unsubscribe_activity_alert`**), and
`20260801130200_alert_subscription_trigger.sql` (re-`create or replace`s
`submit_request` — copied verbatim from
`20260724122600_delete_account_guard.sql`'s version, only the new
notify-subscribers block appended after the `REQUESTING` transition;
watch for future `submit_request` edits landing in a different migration
and forgetting this block exists downstream).

1. `expires_at` belongs to the *subscriber* (how long they're willing to
   wait), not the thing being subscribed to — same soft-expiry shape as
   `app_user.next_request_allowed_at`/`suspended_until`: no cleanup job,
   just filter `expires_at > now()` wherever it matters.
2. Notification payload deliberately omits `request_id` — same reasoning
   as v1.26's `get_campus_pulse`: `match_request` RLS still blocks
   non-owner/member reads regardless, so including an id the client can't
   resolve into anything adds a field with no payoff. The client deep-links
   `ALERT_TRIGGERED` to `/match` (home), not an activity/request detail
   screen — see the new branch in `notifications_screen.dart`'s `_open()`.
3. Not consumed on fire: a subscription can trigger multiple
   `ALERT_TRIGGERED` notifications within its window (each matching new
   `REQUESTING` request is a genuinely new opportunity) — capped instead by
   a max-5-concurrent-active-subscriptions guard in the RPC
   (`TOO_MANY_ALERT_SUBSCRIPTIONS`, new `ApiErrorCode` value), not a
   per-fire rate limit.
4. Wrapped in `lib/rpc/alert_subscription_rpc.dart`;
   `lib/match/match_providers.dart`'s `myActiveAlertSubscriptionsProvider`
   is a plain `FutureProvider` (no realtime need — this is a short list the
   user manages, not a live feed) filtered to `expires_at > now()`. UI is
   `_AlertSubscriptionSection` in `create_request_screen.dart`, next to the
   v1.26 pulse banner.
5. Covered by `supabase/tests/database/27_alert_subscription.test.sql`:
   lookahead-hours bounds, the 5-subscription cap, `submit_request` firing
   `ALERT_TRIGGERED` only for matching/unexpired subscriptions and never
   for the submitter's own, and idempotent unsubscribe.

## v1.28 update: `update_vibe_tags` — Vibe Tags

New feature. Migrations `20260801140000_vibe_tags_schema.sql` (adds
`activity_member.vibe_tags text[]`, count-only CHECK — see that file's
comment for why per-element length validation was deliberately left
RPC-only rather than also a DB CHECK: array-element CHECK constraints have
enough Postgres edge cases that this round didn't want to ship one
untested against a real local instance) and
`20260801140100_vibe_tags_rpc.sql` (**`update_vibe_tags(activity_id,
tags)`**, `SECURITY DEFINER`).

1. Deliberately lives on `activity_member` (post-match), not
   `request_member`/`match_request` (pre-match) — the user explicitly asked
   these never become matching filters. Putting the column post-match makes
   that structurally true (the matching engine never reads this table's new
   column) rather than a policy someone could accidentally violate later by
   wiring it into `fn_run_matching_engine`.
2. Same shape as `update_meeting_hint`: overwrite (not append-only), no
   notification, `JOINED` + `status in (MATCHED, ONGOING)` gate.
3. Tag catalog is a client-side keyword-matched table
   (`_vibeTagOptionsFor()` in `activity_detail_screen.dart`, same pattern as
   `create_request_screen.dart`'s existing `_activityTypeIcon()`) — not a
   backend admin-approved table like `activity_type`. The RPC only
   validates count (≤3) and length (≤20 chars each), never tag content
   against the catalog, so a stale/uncovered client catalog never blocks a
   user from saving.
4. UI: self's card in the Members tab shows tags inline (editable without
   expanding — self's card isn't expandable, see existing `isSelf ? null :`
   tap handler); other members' tags render as read-only chips in the same
   spot regardless of expand state.
5. Covered by `supabase/tests/database/28_vibe_tags.test.sql`: count/length
   limits, overwrite-not-append, empty-array-clears, `ACTIVITY_NOT_ACTIVE`
   boundary, and confirming the matching engine path never touches this
   column (structural, not just tested at the RPC layer).

## v1.29 update: `get_my_badges` — Achievement Badges

New feature. Migration `20260801150000_achievement_badges_rpc.sql` adds
**`get_my_badges()`** — the lowest-risk addition this round: zero schema
change, `stable`/read-only, computed entirely from existing
`user_reliability_event`/`rematch_vote`/`match_request` data (same
"no persisted score, query-time computation" philosophy as
`fn_reliability_tier` itself, SPEC v1.1 change 4).

1. Four badges, all cumulative (not the 30-day rolling window
   `fn_reliability_tier` uses) — deliberate: a badge is a permanent
   milestone ("you did this once"), not a live risk signal, so it
   shouldn't silently un-earn itself after 30 quiet days.
2. Wrapped as `getMyBadges()` in `lib/rpc/auth_profile_rpc.dart`, returning
   a `Set<AchievementBadge>` (Dart enum carrying `code`/`icon`/`label`; the
   RPC itself only returns stable string codes, presentation is client-side).
3. `lib/match/match_providers.dart`'s `myBadgesProvider` (plain
   `FutureProvider`), rendered by `profile_screen.dart`'s new
   `_BadgesSection` directly under the existing reliability-tier card —
   earned badges full-opacity, unearned dimmed (not hidden), loading/error
   states collapse to nothing rather than disrupting the rest of the page.
4. Covered by `supabase/tests/database/29_achievement_badges.test.sql`:
   each badge's threshold (just-under vs just-at), mutual-vs-one-way
   rematch_vote (must be bidirectional to count), and that an unrelated
   user's data never leaks into another user's count.

## v1.29.1 update: robustness fixes across the six v1.24–v1.29 RPCs

Not new features — a targeted correctness pass (concurrency, RLS, delete-account
interaction, error-path coverage) requested against the six features above,
same spirit as v1.14.1's doc-vs-implementation audit. Full rationale in
SPEC.md's v1.29.1 changelog entry; summary here:

1. **`mark_arrived` race fixed** (`20260801160000_fix_mark_arrived_race.sql`):
   the idempotency check was `SELECT` then `UPDATE` as two separate
   statements, so two concurrent calls could both pass the "not yet arrived"
   check and each fire a `MEMBER_ARRIVED` notification. Now a single
   `UPDATE ... WHERE arrived_at IS NULL RETURNING`. `24_arrival_check.test.sql`
   grew from 9 to 11 assertions (adds `ACTIVITY_NOT_FOUND` + `ACCOUNT_DELETED`
   coverage; the idempotency assertion already in place continues to hold
   under the atomic version).
2. **`delete_account()` now clears `meeting_hint`/`vibe_tags`**
   (`20260801160100_fix_delete_account_personal_text.sql`) on every
   `activity_member` row for the deleting user, regardless of status —
   these are free-text fields visible to other members and were never
   de-identified. `13_delete_account.test.sql` grew from 23 to 25 assertions.
3. **`fn_cleanup_alert_subscriptions()` + pg_cron schedule added**
   (`20260801160200_alert_subscription_cleanup.sql`) — the table had no
   cleanup path and grows one row per `subscribe_activity_alert` call, never
   shrinking. New `30_alert_subscription_cleanup.test.sql` (3 assertions).
4. **`ACCOUNT_DELETED` check added** to `update_vibe_tags`,
   `submit_feedback`, `get_campus_pulse`, `subscribe_activity_alert`,
   `unsubscribe_activity_alert`, `get_my_badges`
   (`20260801160300_account_deleted_guard_new_rpcs.sql`), matching the
   convention established in v1.14 and continued in v1.18's `submit_report`.
   `25_feedback.test.sql` (9→10), `26_campus_pulse.test.sql` (4→5),
   `28_vibe_tags.test.sql` (8→10) each grew by one assertion; `27_alert_
   subscription.test.sql` grew by two (9.1 also adds a regression test that
   `unsubscribe_activity_alert` can't delete another user's subscription —
   previously only tested against a nonexistent id, so the `user_id =
   auth.uid()` clause in the `DELETE` had no test actually pinning it);
   `29_achievement_badges.test.sql` (9→10).

## v1.30 update: `propose_activity_location`/`vote_activity_location` — free-text candidates

User feedback: the fixed-list-only rule from v1.10/v1.11 ("候選地點...不開放
自由輸入，延續固定清單原則") didn't hold up once activity types expanded past
on-campus meetups — board games, mahjong, off-campus cafes are one-off venues
that shouldn't need admin review or a permanent slot in the shared `location`
table. Full rationale in SPEC.md's v1.30 changelog entry; summary here:

1. **`propose_activity_location(activity_id, location_id, custom_name)`** —
   `custom_name` is new, optional, and mutually exclusive with `location_id`
   (`INVALID_INPUT` if both or neither given). Giving `custom_name` (1~40
   chars, `INVALID_INPUT` if longer) skips the `APPROVED`/scope check
   entirely and creates a candidate scoped only to that activity — never
   written to `location`. `propose_location` (the existing admin-review path
   for adding to the shared directory) is unchanged and still wired into
   `create_request_screen.dart` per the entry below; the two now serve
   distinct purposes (one-off vs. reusable).
2. **`vote_activity_location(activity_id, option_id)`** — `location_id`
   renamed to `option_id`, now votes target the candidate row
   (`activity_location_option.id`) instead of a location, since a
   `custom_name` candidate has no `location_id` to vote for.
   `activity_location_vote.location_id` → `option_id` in the schema
   (`20260802120000_activity_location_free_text_schema.sql`); RPC rewrite in
   `20260802120100_activity_location_free_text_rpc.sql`.
3. **`activity.activity_location_id`'s FK target changed** from `location(id)`
   to `activity_location_option(id)` — the winning candidate can now be a
   custom one with no `location` row to point at. `fn_start_activities()`'s
   tally/lock query updated to group by `activity_location_option.id` instead
   of `location_id`; the winner selection logic itself (highest votes, ties
   go to earliest `created_at`) is unchanged.
4. **Dart wrapper changes** (`lib/rpc/activity_rpc.dart`):
   `proposeActivityLocation()` gained an optional `customName` param
   alongside the now-optional `locationId` (asserts exactly one is passed);
   `voteActivityLocation()`'s `locationId` param renamed to `optionId`.
   `ActivityLocationOption`/`ActivityLocationVote` regenerated via
   `supadart` (`location_id` now nullable, new `custom_name` field on the
   option; `location_id` → `option_id` on the vote).
5. **UI** (`activity_detail_screen.dart`'s `_LocationVoting`): new "新增這場
   活動的候選地點" button opens a text-input dialog and calls
   `proposeActivityLocation(..., customName: ...)` directly — no review,
   visible/votable immediately. The existing "提議新增到清單" button (admin
   review, unchanged RPC) is relabeled "建議加入官方地點清單" to distinguish
   it from the new instant path. `_LockedLocationCard` now resolves the
   locked name by first looking up the winning `activity_location_option`
   (via `activityLocationOptionsStreamProvider`), then either using its
   `custom_name` directly or resolving `location_id` against
   `approvedLocationsProvider` — it can no longer look `activityLocationId`
   up directly against the location list.
6. **pgTAP**: `06_activity_location_voting.test.sql` grew from 15 to 20
   assertions (both/neither `INVALID_INPUT`, custom candidate creation +
   auto-vote + confirmed not written to `location`, same-name re-propose
   degrades to a vote, `fn_start_activities` can lock a custom candidate).
   `13_delete_account.test.sql`'s fixture updated for the `option_id` column
   rename (assertions themselves were `count(*)`-based, unaffected).

## UI update: `propose_activity_type`/`propose_location` wired into `create_request_screen.dart`

Found during manual testing feedback (敢不敢揪 round): both RPCs, their Dart
wrappers (`proposeActivityType()`/`proposeLocation()`), and their pgTAP
coverage (`05_propose_location.test.sql` etc.) already existed — but no
screen ever called them. The activity-type chip list and campus chip list in
`create_request_screen.dart` only ever showed the existing `APPROVED` catalog
(`search_activity_type` / `campusOptionsProvider`'s distinct-campus query),
with no way for a user to suggest a new one. Not a backend gap, purely a
missing UI entry point — no migration or SPEC.md change needed.

Added two `TextButton`s ("沒有你要的類型/地點？提議新增") under step 1 and
step 3 of the form, each opening a dialog and calling the existing RPC
wrapper. Both submissions land as `status='PENDING'` and are **not**
immediately selectable for the current request — `search_activity_type` and
`active_locations_select` both filter to `APPROVED` only — so the dialogs and
the confirmation `SnackBar` explicitly say "審核通過後才會出現在清單中"
rather than implying instant availability. `DUPLICATE_TYPE_NAME`/
`DUPLICATE_LOCATION_NAME` are mapped to a friendlier message; other
`ApiException`s fall back to showing the raw error code.

## v1.32 update: `complete_profile` gained `p_default_campus` — `app_user.default_campus`

User feedback: `create_request_screen.dart` made the caller re-pick a campus
from the chip list on every single request, even though most users only ever
use one. Full design discussion (including a rejected `campuses` normalized
table proposal) in SPEC.md's v1.32 changelog entry; summary here:

1. **Schema**: `app_user.default_campus` (nullable text, no FK — same
   free-text shape as `location.campus`, not a new normalized concept).
   Migration `20260803130000_app_user_default_campus_schema.sql`. Needed an
   explicit `grant update (default_campus) on app_user to authenticated`
   since `20260724125200_restrict_app_user_notification_column_grants.sql`
   collapsed the old blanket `UPDATE` grant into a column whitelist — adding
   a column doesn't inherit that old grant automatically.
2. **`complete_profile` gained optional `p_default_campus`**
   (`20260803130100_app_user_default_campus_rpc.sql`) — required dropping the
   old 9-arg signature first (`drop function if exists complete_profile(text,
   text, degree_level, text, text, text, text, text, text);`), same class of
   pitfall as v1.30's `propose_activity_location`/`vote_activity_location`:
   adding a trailing default-valued param without dropping the old signature
   creates an ambiguous overload for any 9-arg call site. The upsert's `on
   conflict (id) do update` branch is shared with `edit_profile_screen.dart`
   re-calling this same RPC for unrelated profile edits (never touches
   campus) — used `default_campus = coalesce(excluded.default_campus,
   app_user.default_campus)` so a call that doesn't pass campus can't wipe a
   previously-set value.
3. **Dart wrapper** (`lib/rpc/auth_profile_rpc.dart`): `completeProfile()`
   gained optional `defaultCampus` param, sent as `p_default_campus`.
   `AppUser` regenerated via `supadart` (`defaultCampus` field, only file
   with content changes).
4. **UI — registration** (`complete_profile_screen.dart`): when
   `campusOptionsProvider(school)` resolves 2+ campuses, shows a "你平常在哪個
   校區？" dropdown and requires a selection before submit
   (`_campusOptions.length > 1 && _defaultCampus == null` → inline error,
   same pattern as the existing "至少一項聯絡方式" check). When there's only 1
   campus (current MVP reality for both schools), silently defaults to it —
   no extra tap.
5. **UI — request creation** (`create_request_screen.dart`): the campus chip
   selector's initial value now prefers `user.defaultCampus` (if still a
   valid option) over `campuses.first`; still fully overridable per-request
   (e.g. usually at 光復 but today at 博愛). On successful submit, if the
   campus actually used differs from `user.defaultCampus`, PATCHes it back —
   this is the "always editable" mechanism per the user's requirement,
   without a dedicated settings screen: whatever you pick becomes next time's
   default.
6. **pgTAP**: new `31_default_campus.test.sql` (4 assertions) — first call
   sets `default_campus`; a later call without the param doesn't wipe it
   (coalesce); a later call with a new value overwrites it; a user who never
   passes the param stays `null`.
7. **Explicitly deferred**: a normalized `campuses` table, and a browsable
   homepage feed with a campus filter (`default_campus` is stored now so it's
   ready to be that filter's default once the feed screen exists — no schema
   rework needed then).

## v1.33 update: `bio` becomes a hard registration gate + Dicebear placeholder rejection + profile card

Found while scoping "can I tap a matched member's photo to see a bigger profile
card?" — the answer was no (roster card only expanded to meeting hint +
contacts), and `bio` wasn't even fetched for other members. Two follow-on
decisions came out of that discussion, in SPEC.md's v1.33 changelog entry:

1. **`app_user.bio` NOT NULL** (`20260803150000_bio_avatar_hard_requirements.sql`)
   — backfills existing `null` rows to `''`, then `alter column bio set not
   null, set default ''`. Same two-layer shape as `avatar_url`: DB `NOT NULL`
   is belt-and-suspenders against direct-table writes, the real enforcement is
   `complete_profile`'s new `trim(p_bio) = ''` check (`PROFILE_INCOMPLETE` /
   `BIO_REQUIRED`).
2. **`complete_profile` rejects Dicebear placeholder avatars**: no
   face-detection exists anywhere in this repo (`avatar_upload.dart`'s
   `pickAndUploadAvatar` just uploads raw picked bytes) so the only enforceable
   rule is rejecting the one auto-generated non-uploaded source —
   `complete_profile_screen.dart`'s `_rerollAvatar()` builds a
   `https://api.dicebear.com/...` seed URL, which passed the existing
   `AVATAR_URL_REQUIRED` "non-blank" check just fine. New check:
   `p_avatar_url ~* 'dicebear\.com'` → `PROFILE_INCOMPLETE` /
   `PLACEHOLDER_AVATAR_NOT_ALLOWED`.
3. **Same 10-arg `complete_profile` signature, no `drop function` needed** —
   unlike v1.32's `p_default_campus` addition, this round only adds validation
   inside the existing param list, so `create or replace function
   complete_profile(...)` with the identical signature is enough.
4. **Both new checks apply uniformly to `edit_profile_screen.dart`'s reuse of
   this RPC, not just registration** — same precedent as the pre-existing
   `AVATAR_URL_REQUIRED` check, which already applies to every edit-profile
   save today. There's no way for the RPC to distinguish "first-time
   registration" from "editing an existing profile" (it's the same upsert), so
   this isn't a new special case — it's the existing behavior extended to two
   more fields. Practical effect: any pre-existing user with a blank `bio` or
   still-Dicebear avatar gets asked to fix it the next time they save *any*
   profile edit. Intentional, not a bug — flagged explicitly during planning.
5. **`delete_account()` scrub updated**: `bio = null` → `bio = ''` (same file)
   since `bio` is now `NOT NULL` — mirrors how `avatar_url` was already scrubbed
   to `''` rather than `null` on account deletion.
6. **`get_activity_member_profiles` gained `bio`**
   (`20260803150100_activity_member_profiles_bio.sql`) — added to this RPC,
   not `get_activity_contacts`, per the split both migrations already document:
   `get_activity_contacts` owns identity + time-gated contact fields;
   `get_activity_member_profiles` owns untimed general personal fields
   (already home to `department`, which SPEC.md groups with `bio` as
   "same tier, display-only"). Same signature/access-check, just one more key
   in the `jsonb_build_object`.
7. **Dart wrapper**: `ActivityMemberProfile` (`lib/rpc/activity_rpc.dart`)
   gained a `bio` field; `MemberRosterEntry`
   (`lib/activities/activity_detail_providers.dart`) gained `bio`, populated
   from `profile?.bio`, threaded through both `copyWith*` methods.
8. **UI — profile card** (`activity_detail_screen.dart`): tapping a member's
   `CircleAvatar` specifically (wrapped in its own `InkWell`, separate from the
   card's existing whole-card tap that expands contacts) opens a new
   `showModalBottomSheet` (`isScrollControlled: true`, same pattern as the
   existing `_ReportSheet`/`_RematchSheet`) showing a read-only profile card:
   photo, name, school/department/degree line, full `bio` text (fallback
   "還沒有寫自我介紹" for any legacy member who predates the hard requirement),
   reliability tier.
9. **UI — registration** (`complete_profile_screen.dart`): removed the
   auto-`_rerollAvatar()` call and the "隨機頭像" button entirely — shows an
   empty-state avatar until the user uploads a real photo. `_submit()` gained
   blank-avatar and blank-bio guards (same manual-validation style as the
   existing "至少一項聯絡方式" check). Bio field label changed from
   "自我介紹（選填）" to "自我介紹", with a `hint` nudging content
   ("興趣、有什麼經驗或技能可以跟別人分享…" — `AppTextField` already supports
   `hint`, no widget change needed). Added helper copy near the upload button
   suggesting an actual face photo for recognizability.
10. **UI — `edit_profile_screen.dart`**: mirrors the same `_submit()` guards
    and copy changes, so a legacy user hits a friendly inline error instead of
    a raw `PROFILE_INCOMPLETE`/`e.code.name` string the first time this bites
    them.
11. **pgTAP**: new `32_profile_hard_requirements.test.sql` (8 assertions) —
    covers `BIO_REQUIRED`, `PLACEHOLDER_AVATAR_NOT_ALLOWED`, the success path
    persisting `bio` correctly, and `get_activity_member_profiles` returning
    `bio`. Also closes a coverage gap found while scoping: **zero existing
    pgTAP coverage of any of `complete_profile`'s required-field rejections**
    (the only prior test touching this RPC, `31_default_campus.test.sql`,
    only varies `p_default_campus` and always passes a full valid payload
    otherwise) — backfilled `DISPLAY_NAME_REQUIRED`/`AVATAR_URL_REQUIRED`/
    `DEGREE_LEVEL_REQUIRED`/`NO_CONTACT_METHOD` assertions too while in this
    file. Also updated `31_default_campus.test.sql`'s four `complete_profile`
    calls to pass `p_bio`, since they'd otherwise now fail `BIO_REQUIRED`.

## v1.34/v1.35 update: Skill Level (`skill_level`) + 讀書「同伴目標」(`study_target`)

Two independently-scoped additions to `create_request`/`match_request`,
implemented together since both follow the same "compatibility check folds
into the existing v1.15 N-way candidate-filtering query" shape. See SPEC.md's
v1.34/v1.35 changelog entries and ERD.md design notes 48/49 for the product
rationale; this section only covers implementation-level findings.

1. **`create_request` signature changed twice in this round (7→8→9 params)
   — each change required an explicit `drop function` first**, same class of
   pitfall already documented above for `complete_profile`/
   `propose_activity_location`. `create or replace function` on a *different*
   parameter list doesn't replace the old function, it adds a second
   overload — caught by `supabase test db` failing with `function
   create_request(...) is not unique` on the very first run after adding
   `p_skill_level`. Fixed by adding `drop function if exists
   create_request(uuid, text, timestamptz, timestamptz, int, int, boolean);`
   (and again for the 8-arg version before the `p_study_target` migration) —
   see `20260803160100_skill_level_rpc.sql` / `20260803160300_study_target_rpc.sql`.
2. **Found and did not silently accept: supadart's enum-column `fromJson()`
   fallback bug also fires for *nullable* enum columns, not just NOT NULL
   ones.** The existing "Table-generation notes" entry below only documents
   the fallback firing for NOT NULL columns that come back null/missing. This
   round found a worse variant: `match_request.skill_level` is genuinely
   nullable (null = wildcard, the *normal* case for most requests), but
   supadart's generated `fromJson()` still applies the same
   `SKILL_LEVEL.values.first` fallback template regardless of the column's
   actual nullability — turning every wildcard `null` into
   `SKILL_LEVEL.BEGINNER` silently. Grep across `lib/generated/*` confirms
   this `field != null ? Enum.values.byName(...) : Enum.values.first` shape
   is supadart's unconditional template for every enum-typed column in this
   schema; `match_request.skill_level` is simply the first genuinely nullable
   enum column this repo has generated a model for (every other enum column,
   e.g. `pending_confirmation.user_a_response`, is `NOT NULL DEFAULT
   'NO_RESPONSE'`, so the bug is latent but never actually triggered there).
   Not hand-edited (per this repo's "never hand-edit generated code" rule);
   instead added `decodeMatchRequest()` in `lib/rpc/match_request_rpc.dart`
   that re-nulls `skillLevel` when the raw JSON's `skill_level` key is null,
   and every `MatchRequest.fromJson(...)` call site in the app (5 in
   `match_request_rpc.dart`, 2 in `match_providers.dart`, 1 in
   `my_activities_providers.dart`) was switched to call it instead of the raw
   generated factory.
3. **`get_activity_member_profiles` gained `skill_level`/`study_target`
   without adding any new columns to `activity_member`** — both are read via
   the existing `activity_member.source_request_id` join back to
   `match_request`, which survives past the match (row stays, `status`
   becomes `MATCHED`, never deleted). Same "don't duplicate data that's
   already reachable via an existing FK" reasoning as `bio`'s v1.33 addition
   above, just one join deeper.
4. **`study_target` returned by `get_activity_member_profiles` is the raw
   column, never `study_target_normalized`** — the normalized column exists
   purely for the matching-engine's equality check and is never exposed to
   any client-facing RPC; only `create_request`'s SQL and
   `fn_run_matching_engine` ever reference it.
5. **Dart wrappers**: `ActivityMemberProfile` (`lib/rpc/activity_rpc.dart`)
   gained `skillLevel`/`studyTarget`; `MemberRosterEntry`
   (`lib/activities/activity_detail_providers.dart`) gained the same two
   fields, threaded through both `copyWith*` methods, populated from
   `profile?.skillLevel`/`profile?.studyTarget`. New shared helper
   `lib/data/skill_level_labels.dart` (`skillLevelLabel()`) avoids
   duplicating the 新手/一般/進階/競技 label map across
   `create_request_screen.dart`/`waiting_room_screen.dart`/
   `activity_detail_screen.dart`.
6. **`supadart.yaml` gained a `skill_level` enum entry** (`[BEGINNER, CASUAL,
   ADVANCED, COMPETITIVE]`) — same manual-sync requirement as every other
   Postgres enum in this file (supadart doesn't introspect enum labels on its
   own).
7. **pgTAP**: new `33_skill_level_matching.test.sql` (7 assertions:
   wildcard/same-level/different-level/flag-disabled-write-enforcement, plus
   an end-to-end test through a brand-new `skill_level_enabled=true`
   activity type created inline in the test file — proving the mechanism
   needs zero matching-engine code changes for a future type) and
   `34_study_target_matching.test.sql` (9 assertions: normalization
   equivalence, case-folding, null wildcard, mismatch, a deliberately
   semantically-nonsensical "course name happens to equal exam name" case
   proving the comparison is pure string equality with no understanding of
   meaning, and a direct assertion that `study_target`/
   `study_target_normalized` diverge for the same row while only the
   normalized column affects matching). Both also caught real bugs before
   landing: the two-person-match status assertions initially expected
   `MATCHED` but actually land in `PENDING_CONFIRMATION` (no third invited
   member pushes the accumulated count above 2, same branch
   `15_matching_engine_nway.test.sql`'s scenario ② already documents); and
   `fn_normalize_study_target`'s original implementation (`translate(btrim(p_text),
   ...)`) left a stray trailing half-width space when the input's edge
   whitespace was originally full-width, because `btrim()` only recognizes
   half-width space and ran *before* the full-to-half-width conversion —
   fixed by reordering to `btrim(translate(p_text, ...))`.

## Error codes documented in API.md but never raised

**Status as of v1.14.1 (this round): 7 of the original 8 rows resolved, all
verified against `supabase test db` (141 assertions, all green) plus a manual
`supabase db reset`.** `NAME_BLACKLISTED` is the one deliberately untouched
row — see its own entry below for why. This section is kept for history
(don't delete resolved rows), each row now states its resolution.

| Code | Documented at | What actually happens instead | Resolution (v1.14.1) |
|---|---|---|---|
| `NAME_BLACKLISTED` | §2.3 `propose_activity_type` | No blacklist check exists at all (verified: no `blacklist` string anywhere in migrations). Only empty-name (`INVALID_INPUT`, itself undocumented until this round) and exact-duplicate (`DUPLICATE_TYPE_NAME`) are checked. | **Deliberately left untouched.** Flagged and explicitly deferred by the user in an earlier round (see the v1.10 update section above, "propose_activity_type's documented blacklist precheck was never actually implemented either") and reconfirmed out of scope for this round specifically so this cleanup pass wouldn't quietly absorb it. Still an open gap — pick it up as its own dedicated round. |
| `INVITE_LINK_REVOKED` | §3 error table | `join_request_by_token` only ever raises `INVITE_LINK_EXPIRED`, for missing/revoked/expired tokens alike (single `where invite_token = ... and revoked_at is null` filter, one raise site). | **Docs fixed, no code change.** The single-code behavior is the right design — the caller's remedy is identical in all three cases (ask the owner for a fresh link), so a separate code would carry information nobody consumes. Removed from API.md §3's error table with a note explaining why `INVITE_LINK_EXPIRED` alone is correct. |
| `INVALID_PENDING_CONFIRMATION` | §4 error table | A nonexistent `pending_confirmation_id` raises `NOT_FOUND` (detail `PENDING_CONFIRMATION_NOT_FOUND`) instead, same convention as every other lookup RPC. | **Docs fixed, no code change.** API.md §4 now documents `NOT_FOUND` (detail `PENDING_CONFIRMATION_NOT_FOUND`) instead, matching the convention already used by every other lookup RPC (`REQUEST_NOT_FOUND`, `ACTIVITY_NOT_FOUND`, `DOWNGRADE_REQUEST_NOT_FOUND`, `LOCATION_OPTION_NOT_FOUND`). |
| `ALREADY_RESPONDED` (§4 `respond_pending_confirmation` only) | — | Confirmed *not* raised for this endpoint — matches API.md's own v1.7 note that the code was intentionally removed from §4 ("允許反悔"). §5's `respond_downgrade` is a *different* endpoint and does raise `ALREADY_RESPONDED` (§5's error table still lists it, unlike §4's) — see the confirmed-matches section below. | **Untouched — already correct.** Not part of this round's scope (already resolved/confirmed in v1.7, listed here only for completeness). |
| `CONTACT_EXPIRED` | §6 error table | `get_activity_contacts` never throws for this; it returns HTTP 200 with `members[].contacts == null`. Client must branch on null, not catch an exception. | **Docs fixed, no code change.** The null-contacts design is correct as-is (lets the client always render the member list without a try/catch for a routine, expected state) and is independent of `activity.status` on purpose — contacts must stay visible after the activity ends, that's the entire point of the endpoint. Removed from API.md §6's error table; 6.2's description now states the null-return behavior explicitly. |
| `ACTIVITY_ALREADY_ENDED` | §6 error table | Not checked by either `get_activity_contacts` or `cancel_activity_participation`. | **Split judgment — one doc fix, one real code fix.** `get_activity_contacts`: doc fix only, no status gate needed (see `CONTACT_EXPIRED` row above — visibility is governed by `contact_visible_until` + mutual rematch, not `activity.status`, by design). `cancel_activity_participation`: **real gap, fixed in code** — STATE_MACHINE.md A5/A6 only define `MATCHED`/`ONGOING` as valid source states, but the RPC never checked `activity.status` at all, so calling it against an already-`COMPLETED`/`CANCELLED` activity would incorrectly record a `LATE_CANCEL` reliability event and trigger the cooldown. Fixed in `20260724122800_fix_activity_validation_gaps.sql` by reusing the existing `ACTIVITY_NOT_ACTIVE` code (same `status not in (MATCHED, ONGOING)` gate 6.6/6.7 already use) rather than implementing the never-raised `ACTIVITY_ALREADY_ENDED`. Covered by `14_activity_validation_gaps.test.sql` (assertions 1–2). `ACTIVITY_ALREADY_ENDED` itself is now removed from API.md entirely — nothing needs it. |
| `ACTIVITY_NOT_ENDED` | §7 error table | `submit_completion_report` has no gate on `activity.status`/`start_time` before accepting a report. | **Real gap, fixed in code.** Added a `activity.status = 'ONGOING'` requirement in `20260724122800_fix_activity_validation_gaps.sql`, raising `ACTIVITY_NOT_ENDED` otherwise (blocks both "not started yet" `MATCHED` and "already settled/cancelled" `COMPLETED`/`CANCELLED` submissions). This incidentally closes a latent duplicate-settlement bug: the settlement loop re-runs in full every time `report_count >= quorum` with no "already settled" guard, so a report arriving after the activity had already flipped to `COMPLETED` would have re-inserted `user_reliability_event` rows for every member a second time. Covered by `14_activity_validation_gaps.test.sql` (assertions 3–5). |
| `INVALID_ABSENT_TARGET` | §7 error table | `absent_user_ids` is inserted with no check that the ids are actually members of the activity. | **Real gap, fixed in code.** Added a membership check in the same migration: every id in `p_absent_user_ids` must be a `JOINED` member of `p_activity_id`, else `INVALID_ABSENT_TARGET`. Covered by `14_activity_validation_gaps.test.sql` (assertions 6–7, plus a regression check in assertions 8–9 that a legitimate member id still submits successfully). |

## Error codes raised in practice but not documented

**Status as of v1.14.1: all 3 rows below are now documented in API.md**
(§2/§3/§7 error tables for `INVALID_INPUT`'s various sites, §3 for the
participant-count codes, §4 for `FORBIDDEN`/`NOT_PARTY_TO_CONFIRMATION`).
Rows kept here for history/traceability, not because the gap still exists.

| Code | Raised by | Detail | Resolution (v1.14.1) |
|---|---|---|---|
| `INVALID_INPUT` | `create_request`, `propose_activity_type`, `propose_location` (v1.10), `rematch_vote` | Generic catch-all for malformed input (empty name, invalid time window, unknown activity type, voting for yourself). Always carries a `detail` distinguishing the case. `create_request`'s time-window details (v1.16, since the old `bucket` param was replaced by direct `earliest_start`/`latest_start` timestamps): `LATEST_START_MUST_BE_AFTER_EARLIEST_START`, `LATEST_START_IN_PAST`. | Added to API.md §2 (propose_activity_type/propose_location), §3 (create_request), §7 (rematch_vote) error tables. |
| `INVALID_MIN_PARTICIPANTS` / `INVALID_MAX_PARTICIPANTS` | `create_request` | `min_participants < 2`, or `max_participants < min_participants`. | Added to API.md §3 error table. |
| `FORBIDDEN` (detail `NOT_PARTY_TO_CONFIRMATION`) | `respond_pending_confirmation` | Caller is neither request_a's nor request_b's owner. | Added to API.md §4 error table. |

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
