import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart' show PENDING_CONFIRMATION_STATUS;
import 'rpc_client.dart';

class PendingConfirmationStatus {
  final String pendingConfirmationId;
  final PENDING_CONFIRMATION_STATUS status;
  final DateTime confirmWindowExpireAt;

  PendingConfirmationStatus({
    required this.pendingConfirmationId,
    required this.status,
    required this.confirmWindowExpireAt,
  });
}

/// docs/API.md §4.1 — `rpc: get_pending_confirmation_status(request_id)`.
/// `status` reuses supadart's generated `PENDING_CONFIRMATION_STATUS` enum —
/// same underlying Postgres type as the `pending_confirmation.status` column
/// (supabase/migrations/20260724120400_rpc_matching_engine.sql:193-197).
/// Per the "對稱不歸因原則" (ERD note 16) this deliberately never exposes
/// `user_a_response` / `user_b_response`.
///
/// GAP vs docs/API.md: the doc's §4 error table lists
/// `INVALID_PENDING_CONFIRMATION`. The migration never raises that code —
/// a nonexistent pending_confirmation_id raises `NOT_FOUND` (detail
/// `PENDING_CONFIRMATION_NOT_FOUND`) instead, same as every other lookup RPC.
Future<PendingConfirmationStatus> getPendingConfirmationStatus(
  SupabaseClient client,
  String requestId,
) {
  return callRpc<PendingConfirmationStatus>(
    client,
    'get_pending_confirmation_status',
    params: {'p_request_id': requestId},
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return PendingConfirmationStatus(
        pendingConfirmationId: json['pending_confirmation_id'] as String,
        status: PENDING_CONFIRMATION_STATUS.values.byName(
          json['status'] as String,
        ),
        confirmWindowExpireAt: DateTime.parse(
          json['confirm_window_expire_at'] as String,
        ),
      );
    },
  );
}

/// docs/API.md §4.2 — `rpc: respond_pending_confirmation(pending_confirmation_id, confirm)`.
/// Repeat calls within the window overwrite the previous response (v1.7
/// "允許反悔" clarification — `ALREADY_RESPONDED` was removed from the spec
/// and, confirmed here, is not raised by the migration).
///
/// GAP vs docs/API.md: a caller who is neither request_a's nor request_b's
/// owner raises `FORBIDDEN` (detail `NOT_PARTY_TO_CONFIRMATION`) — this code
/// is not declared in API.md §0 or §4 at all.
Future<void> respondPendingConfirmation(
  SupabaseClient client, {
  required String pendingConfirmationId,
  required bool confirm,
}) {
  return callRpc<void>(
    client,
    'respond_pending_confirmation',
    params: {
      'p_pending_confirmation_id': pendingConfirmationId,
      'p_confirm': confirm,
    },
    decode: (_) {},
  );
}
