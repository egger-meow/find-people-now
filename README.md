# Find People Now

Find People Now is a completed Flutter MVP for helping students at NYCU and NTHU form small, time-bounded activity groups. It supports onboarding, request creation, matching, pending-confirmation flows, activity coordination, notifications, reporting, and account deletion.

## What is in this repository

- `app/` — the Flutter client, including the production UI, typed Supabase RPC wrappers, and integration tests.
- `supabase/` — database migrations, Edge Functions, pgTAP database tests, and local Supabase configuration.
- `docs/` — the product specification, ERD, state machine, and API contract.

## Stack

- Flutter / Dart
- Supabase: Auth, PostgreSQL, Row Level Security, Realtime, Storage, Edge Functions, and `pg_cron`
- Firebase Cloud Messaging
- Google Maps API

## Key capabilities

- NYCU/NTHU profile onboarding with campus selection
- Activity discovery and request creation with flexible participant counts and time windows
- Matching with pending confirmation, downgrade handling, block/report controls, and history avoidance
- Activity location proposals and voting, meeting-point updates, arrival checks, reminders, and completion flows
- Realtime updates, notifications, feedback, achievement badges, and account deletion

## Development

The database migrations and tests are runnable locally with the Supabase CLI. For Flutter-specific setup, environment variables, generated types, and smoke tests, see [app/README.md](app/README.md).

```bash
supabase start
supabase test db
```

## Documentation

The product and backend contracts are maintained here:

- [Product specification](docs/SPEC.md)
- [Database ERD](docs/ERD.md)
- [State machine](docs/STATE_MACHINE.md)
- [API contract](docs/API.md)

## Database security

Client-accessible database operations go through explicitly authorized RPCs and Row Level Security. Background matching and cleanup functions are restricted to trusted database roles and scheduled by `pg_cron`; they are not anonymous API endpoints.
