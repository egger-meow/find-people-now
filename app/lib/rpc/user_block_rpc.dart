import 'package:supabase_flutter/supabase_flutter.dart';

import 'rpc_client.dart';

/// docs/API.md — `rpc: block_user(p_blocked_id, p_reason)`.
/// Idempotent: calling again for the same [blockedId] just overwrites [reason].
Future<void> blockUser(
  SupabaseClient client, {
  required String blockedId,
  String? reason,
}) {
  return callRpc<void>(
    client,
    'block_user',
    params: {
      'p_blocked_id': blockedId,
      'p_reason': reason,
    },
    decode: (_) {},
  );
}

/// docs/API.md — `rpc: unblock_user(p_blocked_id)`.
/// Idempotent: no error if [blockedId] was never blocked.
Future<void> unblockUser(
  SupabaseClient client, {
  required String blockedId,
}) {
  return callRpc<void>(
    client,
    'unblock_user',
    params: {
      'p_blocked_id': blockedId,
    },
    decode: (_) {},
  );
}
