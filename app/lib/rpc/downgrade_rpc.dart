import 'package:supabase_flutter/supabase_flutter.dart';

import 'rpc_client.dart';

/// docs/API.md §5.1 — `rpc: respond_downgrade(downgrade_request_id, agree)`.
///
/// No wrapper existed until this migration
/// (supabase/migrations/20260724120900_rpc_respond_downgrade.sql) — the
/// endpoint itself didn't exist in the backend. Only the user-facing
/// *response* half is covered here; creating a `downgrade_request` is a
/// background-task responsibility (docs/API.md §9 "Request 過期"), not a
/// client-callable RPC (API.md §5.1: "發起端是系統（Matching Engine),沒有
/// 使用者發起的 endpoint"), and that scheduler is not implemented yet.
///
/// Unlike `respond_pending_confirmation` (§4.2, which explicitly allows
/// changing your mind within the window), `respond_downgrade` rejects a
/// second call from the same user with `ALREADY_RESPONDED` — API.md §5's
/// error table still lists that code for this endpoint (it was only removed
/// from §4's table in v1.7, not §5's).
Future<void> respondDowngrade(
  SupabaseClient client, {
  required String downgradeRequestId,
  required bool agree,
}) {
  return callRpc<void>(
    client,
    'respond_downgrade',
    params: {'p_downgrade_request_id': downgradeRequestId, 'p_agree': agree},
    decode: (_) {},
  );
}
