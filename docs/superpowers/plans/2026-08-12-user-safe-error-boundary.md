# User-Safe Error Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent every user-facing Flutter surface from exposing developer-only exceptions, backend details, stack traces, or raw error codes.

**Architecture:** Add a central presentation mapper that converts allowlisted `ApiErrorCode` values and error contexts into local Traditional Chinese copy, with a fixed generic fallback. Route page, dialog, form, SnackBar, and asynchronous loading errors through it, then add a root `ErrorWidget.builder` fallback that never renders Flutter diagnostics to users.

**Tech Stack:** Flutter, Dart, Riverpod, Supabase/PostgREST, flutter_test

## Global Constraints

- Do not change backend, schema, RPC signatures, routes, or state machines.
- Preserve actionable Traditional Chinese business guidance through a local allowlist.
- Never display server-provided messages, details, hints, raw codes, exception strings, or stack traces.
- Unknown errors use `Oops！系統出了點狀況，請稍後再試`.
- Implement directly and verify afterward; the user explicitly does not want TDD.

---

### Task 1: Central user-safe error presentation

**Files:**
- Create: `app/lib/errors/user_error_message.dart`
- Create: `app/lib/widgets/app_error_state.dart`
- Test: `app/test/user_error_message_test.dart`

**Interfaces:**
- Produces: `String userErrorMessage(Object error, {required UserErrorContext context})`
- Produces: `UserErrorContext` values for loading and supported actions.
- Produces: `AppErrorState({String? message, VoidCallback? onRetry})`.

- [ ] Implement a closed, local mapping for actionable `ApiErrorCode` values and context-specific safe fallback copy.
- [ ] Ensure unknown errors always return the fixed Oops message and optionally log the original error only in debug mode.
- [ ] Implement a Calm Glass-compatible reusable error state with an optional retry action.
- [ ] Add post-implementation unit/widget coverage for known mapping, unknown exception sanitization, and absence of raw server text.
- [ ] Run `flutter test test/user_error_message_test.dart`.

### Task 2: Sanitize existing user-facing paths

**Files:**
- Modify: `app/lib/match/create_request_screen.dart`
- Modify: `app/lib/match/waiting_room_screen.dart`
- Modify: `app/lib/activities/activity_detail_screen.dart`
- Modify: `app/lib/activities/pending_confirmation_card.dart`
- Modify: `app/lib/auth/complete_profile_screen.dart`
- Modify: `app/lib/downgrade/downgrade_consent_dialog.dart`
- Modify: `app/lib/profile/profile_screen.dart`
- Modify: `app/lib/profile/edit_profile_screen.dart`
- Modify: `app/lib/profile/feedback_screen.dart`
- Modify: `app/lib/notifications/notifications_screen.dart`
- Test: focused existing widget tests plus `app/test/user_error_message_test.dart`

**Interfaces:**
- Consumes: `userErrorMessage(...)` and `AppErrorState` from Task 1.
- Produces: no user-visible interpolation of raw runtime errors in all scanned production paths.

- [ ] Replace every `$error`, `code.name`, `detail`, and exception-derived UI string with central safe presentation.
- [ ] Keep existing validation copy and explicitly allowlisted actionable messages intact.
- [ ] Use `AppErrorState` for asynchronous page/section loading failures where a retry callback is available.
- [ ] Run a production-only `rg` audit for unsafe interpolation and inspect every remaining match.
- [ ] Run focused widget tests for create, waiting, activity detail, confirmation, activities, and profile flows.

### Task 3: Root framework fallback and final verification

**Files:**
- Modify: `app/lib/main.dart`
- Test: `app/test/user_error_boundary_widget_test.dart`

**Interfaces:**
- Consumes: the generic safe copy and reusable error state from Task 1.
- Produces: a root `ErrorWidget.builder` that never renders developer diagnostics.

- [ ] Install the fallback before `runApp`, retaining framework error reporting for developer logs.
- [ ] Add post-implementation coverage proving a build exception shows only friendly copy and no exception text or stack trace.
- [ ] Run `flutter analyze`.
- [ ] Run relevant focused tests, then `flutter test` for final regression.
- [ ] Review `git diff --check`, commit with `fix: prevent technical errors from reaching users`, and push the current branch.
