# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

校園活動配對 App (find-people-now): lets students at NYCU/NTHU spontaneously find people for an
activity (basketball, coffee, studying, etc.) within 24 hours, via blind matching rather than
browsing/picking people. MVP scope is NYCU + NTHU only; cross-school matching is a deliberately
deferred future feature.

Two-part repo:
- `supabase/` — the actual backend: Postgres schema, RLS policies, and all business logic as
  `SECURITY DEFINER` SQL RPC functions, plus pgTAP tests.
- `app/` — a Flutter client that is currently a **type-generation + RPC-wrapper skeleton, not a
  built UI**. See [app/lib/rpc/RPC_COVERAGE.md](app/lib/rpc/RPC_COVERAGE.md) for exactly what's
  wired up vs. still missing.

## Documentation hierarchy — read this before making product/schema decisions

[docs/SPEC.md](docs/SPEC.md) is the **single source of truth**. It is a changelog-style doc (v1.1
through v1.21+); every decision, including *why an alternative was rejected*, is recorded there
before ERD/State Machine/API docs are updated. If any other doc conflicts with SPEC.md, SPEC.md
wins — fix SPEC.md first, then propagate.

- [docs/ERD.md](docs/ERD.md) — data model, enum definitions
- [docs/STATE_MACHINE.md](docs/STATE_MACHINE.md) — `MatchRequest` and `Activity` state machines
  (separate graphs; transitions numbered R1–R5 / PC1–PC2 / A1–A6, referenced by that numbering
  throughout SPEC.md, API.md, and migration comments)
- [docs/API.md](docs/API.md) — endpoint spec, derived from SPEC + ERD + STATE_MACHINE

When changing backend behavior, expect to touch: SPEC.md changelog entry → ERD/STATE_MACHINE/API.md
if affected → migration SQL → pgTAP test → (if client-facing) `app/lib/rpc/*` wrapper +
`app/lib/rpc/RPC_COVERAGE.md`. Migration filenames are timestamped and read chronologically like a
second changelog — check the last few before adding a new one to understand recent context.

## Backend architecture (`supabase/`)

- **All state transitions go through `SECURITY DEFINER` RPC functions**, never direct table
  updates from the client. Pure reads go through PostgREST (relying on RLS). This split is a hard
  rule stated in API.md §0 — don't add a client-side `UPDATE`/direct write path for something that
  should be an RPC.
- **Error convention**: RPCs raise with `raise exception using message = '<CODE>'` (add
  `detail = '<...>'` for sub-reasons). **Never use `errcode = '<CODE>'`** — PL/pgSQL's `errcode`
  only accepts real SQLSTATE codes/condition names; a custom string throws
  `unrecognized exception condition` and silently destroys the intended error (this was a
  repo-wide bug fixed in v1.7, see SPEC.md). PostgREST surfaces `message` as the error's `message`
  field; clients match on that.
- **Table grants are separate from RLS.** Postgres requires table-level `GRANT` before RLS is even
  evaluated — a table can have perfect RLS policies and still 403 everyone with no grants (this was
  a repo-wide gap until `20260724120800_grants.sql`, fixed per-table to match each table's actual
  RLS policy set, not a blanket `grant all`). If a new table needs PostgREST access, it needs an
  explicit grant, not just a policy.
- **Some tables intentionally have RLS enabled but zero SELECT policy** (`pending_confirmation`,
  `match_history_avoidance`) to force reads through a `SECURITY DEFINER` RPC that only reveals an
  aggregate status, never the other party's individual response (non-attribution is a deliberate
  privacy property — see SPEC.md §12.1).
- **A "member of X can see other members of X" SELECT policy must not query its own table inside
  its own `USING (...)` clause** — Postgres detects that as infinite recursion (`42P17`) and errors
  outright, it doesn't just run slow. Wrap the membership check in a `stable security definer` helper
  function instead (see `fn_is_activity_member`, `fn_is_request_member` —
  `20260724121900_fix_activity_member_rls_recursion.sql` /
  `20260724124900_fix_request_member_rls_recursion.sql`); the helper runs as its owner, so it never
  re-triggers the caller's RLS. This bug shipped twice before being caught, both times because every
  other pgTAP test queries as the `postgres` superuser (bypassing RLS) — `35_rls_no_self_reference_smoke.test.sql`
  now walks every RLS-enabled public table as `authenticated` and asserts none of them raise `42P17`,
  so a new self-referencing policy fails CI generically instead of waiting to be found by hand.
- **Background jobs are plain callable SQL functions**, not automatically scheduled — e.g.
  `fn_run_matching_engine`, `fn_cleanup_pending_confirmations`, `fn_start_activities`,
  `fn_expire_requests`, `fn_expire_downgrades`, `fn_complete_activities`,
  `fn_remind_missing_location_candidates`, `fn_remind_upcoming_activities`,
  `fn_remind_completions`. As of the `pg_cron`-scheduling migration
  (`20260724125500_schedule_background_jobs.sql`) these are wired to run periodically; check that
  migration before assuming a job is or isn't scheduled.
- **Matching engine** (`fn_run_matching_engine`) uses an N-way accumulation algorithm within a
  group defined by `(activity_type_id, school, campus)`: pick the oldest still-`REQUESTING`
  request not yet tried this run as a seed, greedily fold in compatible candidates (mutual time
  overlap across the *entire* accumulated set, no `match_history_avoidance`/`user_block` conflict
  with any accumulated owner, overlapping `[min_participants, max_participants]` with the seed)
  until the seed's `min_participants` is met. Branch to `PENDING_CONFIRMATION` vs. direct
  `Activity` creation is decided by **actual accumulated headcount**, not the seed's static
  `min_participants` field — see SPEC.md v1.15 for why the static-field shortcut was tried and
  reverted (an edge case with `max_participants = NULL` breaks the equivalence).
- **`app_config` table** holds tunable operational parameters (cooldowns, confirm windows, etc.) as
  text values cast per-key by helper functions (`fn_get_config_interval`,
  `fn_get_config_int_array`) — not hardcoded in RPC bodies, so ops can retune via Dashboard without
  a redeploy.
- **Account deletion doesn't hard-delete `app_user`** (would cascade-break 13+ FK'd child tables).
  `delete_account()` RPC de-identifies the row in place (`deleted_at` set, PII columns cleared) and
  is idempotent; a companion Edge Function (`supabase/functions/delete-auth-user/`) is the only
  code holding the `service_role` key needed to call `auth.admin.deleteUser(..., shouldSoftDelete:
  true)`.

## Flutter app (`app/`)

- `lib/generated/` — [supadart](https://pub.dev/packages/supadart)-generated table classes for all
  `public.*` tables (config in `app/supadart.yaml`). **Never hand-edit; regenerate instead**:
  ```bash
  dart pub global activate supadart
  supadart --url http://127.0.0.1:54321 --key <SERVICE_ROLE_KEY>
  ```
  Enum values in `supadart.yaml` are hand-synced from `pg_type`/`pg_enum` — update them manually
  when a migration adds/renames an enum label.
- `lib/rpc/` — hand-written typed RPC wrappers. No codegen tool (neither `supadart` nor
  `supabase_codegen_flutter`) reads PostgREST's `/rpc/*` OpenAPI paths, so there is no generated
  equivalent of TypeScript's `Database['public']['Functions']` — these wrappers are manually kept
  in sync with the SQL. Always check
  [app/lib/rpc/RPC_COVERAGE.md](app/lib/rpc/RPC_COVERAGE.md) before assuming an endpoint exists or
  behaves as API.md describes; it documents real API.md-vs-migration drift found by cross-checking.
- State: `flutter_riverpod`. Routing: `go_router`. Backend client: `supabase_flutter`. Env vars
  loaded via `flutter_dotenv` from `app/.env` (git-ignored; shape documented in `app/.env.example`).

## Commands

### Backend (from repo root)

```bash
supabase start                  # local stack (Postgres :54322, API :54321, Studio :54323)
supabase db reset                # reapply all migrations from scratch
supabase test db                 # run all pgTAP tests in supabase/tests/database/
supabase stop
```

Run a single pgTAP file:
```bash
docker exec supabase_db_find-people-now psql -U postgres -d postgres \
  -f /path/inside/container/to/test.sql
```
(or use `supabase test db` — it runs the whole `supabase/tests/database/` suite; there's no
documented per-file CLI flag, so isolate by temporarily moving other files out if needed.)

CI (`.github/workflows/supabase-db-tests.yml`) runs `supabase db start` + `supabase test db` on any
push/PR touching `supabase/**`.

A second workflow (`.github/workflows/flutter-tests.yml`) runs the Flutter suite — including the
integration tests in `app/test/` that drive a real local Supabase instance — on push/PR touching
`app/**` **or** `supabase/**` (a backend migration can break the RPC contract the Flutter layer
relies on without touching `app/` at all). It starts `supabase start`, writes `app/.env` from
`supabase status -o env`, seeds the `光復` test location row the same way
[app/README.md](app/README.md) documents for local runs, then runs `flutter analyze` and
`flutter test`.

### Flutter app (from `app/`)

```bash
cd ..                            # repo root
supabase start
supabase status -o env           # copy ANON_KEY / SERVICE_ROLE_KEY into app/.env
cd app
flutter pub get
flutter run
flutter analyze                  # lint (flutter_lints)
flutter test                     # all tests
flutter test test/rpc_smoke_test.dart
flutter test test/activity_location_voting_smoke_test.dart
```

The two `*_smoke_test.dart` files run against a **real local `supabase start` instance** (not
mocked) and need a `location` row seeded first (no migration seeds `location` rows, only
`activity_type` does):
```bash
docker exec supabase_db_find-people-now psql -U postgres -d postgres -c \
  "insert into location (school, campus, name, is_active) values ('NYCU', '光復', 'Flutter 驗證測試地點', true) on conflict (school, name) do update set is_active = true, campus = excluded.campus;"
```

## Commit convention

Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, etc.) — see
[.agents/AGENTS.md](.agents/AGENTS.md).
