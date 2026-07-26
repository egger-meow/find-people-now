# find_people_now (Flutter client)

Flutter project skeleton for the 校園活動配對 App backend defined under
`../supabase/` and `../docs/API.md`. This is a type-generation + RPC-wrapper
skeleton, not a UI — see `lib/rpc/RPC_COVERAGE.md` for what's implemented and
what's found-but-not-implemented in the backend.

## Layout

- `lib/generated/` — [supadart](https://pub.dev/packages/supadart)-generated
  Dart classes for all 18 `public.*` tables (config: `supadart.yaml`). Never
  hand-edit; regenerate (see below).
- `lib/rpc/` — hand-written typed wrappers for the 21 client-facing RPCs
  (Postgres functions). No Dart codegen tool generates RPC parameter/return
  types (neither `supadart` nor `supabase_codegen_flutter` reads PostgREST's
  `/rpc/*` OpenAPI paths) — see `lib/rpc/RPC_COVERAGE.md` for the full
  docs/API.md ↔ migrations cross-reference, including several
  documented-but-unimplemented endpoints and error codes found while writing
  this.
- `test/rpc_smoke_test.dart` — real (not mocked) verification run against a
  local `supabase start` instance.

## Setup

```bash
cd ..                       # repo root
supabase start
supabase status -o env      # copy ANON_KEY / SERVICE_ROLE_KEY into app/.env — see .env.example
cd app
flutter pub get
```

`.env` is git-ignored (`.gitignore`); `.env.example` documents the shape.

## Regenerating table types

```bash
dart pub global activate supadart
supadart --url http://127.0.0.1:54321 --key <SERVICE_ROLE_KEY>
```

Enum values in `supadart.yaml` are hand-synced from `pg_type`/`pg_enum` —
update them if a migration adds/renames an enum label.

## Running the verification test

Needs a location row to exist (no migration seeds `location` rows — only
`activity_type` gets seed data). The test reads it via `docker exec ...
psql` rather than `client.from('location').select()`, matching how the
seed step below writes it — this is just fixture setup, not a workaround
for a permissions bug (see `20260724120800_grants.sql` — the table-level
GRANTs that endpoint needed were missing until v1.9, now fixed):

```bash
docker exec supabase_db_find-people-now psql -U postgres -d postgres -c \
  "insert into location (school, campus, name, is_active) values ('NYCU', '光復', 'Flutter 驗證測試地點', true) on conflict (school, name) do update set is_active = true;"

flutter test test/rpc_smoke_test.dart
```
