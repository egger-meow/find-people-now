import 'package:supabase_flutter/supabase_flutter.dart';

import 'rpc/auth_profile_rpc.dart';

/// Result of running [deleteAccountFlow] to completion (i.e. the user
/// confirmed and the flow was not cancelled). [authDeleted] can be false even
/// on a "successful" run — see the class doc on why that's still an
/// acceptable end state.
class AccountDeletionResult {
  final bool dataCleanedUp;
  final bool authDeleted;
  AccountDeletionResult({required this.dataCleanedUp, required this.authDeleted});
}

/// Full account-deletion flow, orchestrated client-side across two backend
/// calls that cannot be merged into one (see docs/SPEC.md v1.14 changelog for
/// why `auth.users` deletion needs a service_role-holding Edge Function while
/// everything else is a plain SQL RPC):
///
///   1. `delete_account()` RPC — de-identifies `app_user` + cleans up
///      business data. Idempotent, safe to call more than once.
///   2. `delete-auth-user` Edge Function — calls the official
///      `auth.admin.deleteUser(id, shouldSoftDelete: true)`.
///   3. Local sign-out, unconditionally.
///
/// Verified against a real local instance (not assumed): the underlying
/// `admin.deleteUser` call is idempotent, but the Edge Function resolves the
/// caller's identity first via `getUser(jwt)`, and that rejects an
/// already-deleted account's token with 401 — so a *retry* after a genuine
/// success looks like a failure, not a silent no-op. The retry loop below
/// still converges correctly: it only ever retries because step 2 is
/// unconfirmed, and gives up (then signs out locally) either way.
///
/// [confirm] is the "are you sure, this can't be undone" gate — deliberately
/// left as a caller-supplied async callback rather than a canned dialog here,
/// since this module has no UI dependency. Wire it to a real confirmation
/// dialog before this ships; until then, pass a callback that always
/// resolves `false` in tests, or `true` for a scripted/manual smoke test.
///
/// Step 2 gets 2 retries with a short backoff (1s, then 3s) and then gives
/// up — deliberately not a background retry queue. By the time step 2 could
/// fail, step 1 has already de-identified the account and every
/// identity-checked RPC now rejects it with `ACCOUNT_DELETED`, so the only
/// residual risk is the `auth.users` row surviving a bit longer than
/// intended, which is bounded by GoTrue's own access-token TTL regardless of
/// how it gets deleted. Not worth a persistent retry mechanism for that
/// window.
Future<AccountDeletionResult> deleteAccountFlow(
  SupabaseClient client, {
  required Future<bool> Function() confirm,
}) async {
  final confirmed = await confirm();
  if (!confirmed) {
    return AccountDeletionResult(dataCleanedUp: false, authDeleted: false);
  }

  await deleteAccount(client);

  final authDeleted = await _invokeDeleteAuthUserWithRetry(client);

  // Local sign-out regardless of step 2's outcome: the account is already
  // de-identified and every guarded RPC now rejects this identity, so there
  // is nothing left for this session to usefully do.
  await client.auth.signOut();

  return AccountDeletionResult(dataCleanedUp: true, authDeleted: authDeleted);
}

Future<bool> _invokeDeleteAuthUserWithRetry(SupabaseClient client) async {
  const backoffs = [Duration(seconds: 1), Duration(seconds: 3)];
  for (var attempt = 0; ; attempt++) {
    try {
      await client.functions.invoke('delete-auth-user');
      return true;
    } catch (_) {
      if (attempt >= backoffs.length) return false;
      await Future.delayed(backoffs[attempt]);
    }
  }
}
