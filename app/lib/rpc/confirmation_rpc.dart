import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart'
    show DEGREE_LEVEL, PENDING_CONFIRMATION_STATUS, SCHOOL;
import 'auth_profile_rpc.dart' show ReliabilityTier;
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

class PendingConfirmationCandidateInfo {
  final String displayName;
  final String avatarUrl;
  final SCHOOL school;
  final String? department;
  final DEGREE_LEVEL degreeLevel;
  final ReliabilityTier reliabilityTier;
  final int completedActivityCount;

  PendingConfirmationCandidateInfo({
    required this.displayName,
    required this.avatarUrl,
    required this.school,
    required this.department,
    required this.degreeLevel,
    required this.reliabilityTier,
    required this.completedActivityCount,
  });
}

/// docs/API.md §4.3 — `rpc: get_pending_confirmation_candidate_info(pending_confirmation_id)`
/// (v1.22, migration 20260724125600). Returns the *other* party's SPEC
/// §12.1.3 "安全資訊卡" fields — this RPC didn't exist until this round; see
/// SPEC.md's v1.22 changelog entry for why (§12.1.3 was defined in v1.4 but
/// `get_pending_confirmation_status` never carried counterpart profile data,
/// and `pending_confirmation` itself has RLS enabled with no SELECT policy).
///
/// Same authorization as [respondPendingConfirmation]: caller must be the
/// owner of `request_a` or `request_b`, else `FORBIDDEN` detail
/// `NOT_PARTY_TO_CONFIRMATION`. Deliberately does not expose
/// `user_a_response`/`user_b_response` — the symmetric non-attribution
/// guarantee [getPendingConfirmationStatus] provides is unaffected.
Future<PendingConfirmationCandidateInfo> getPendingConfirmationCandidateInfo(
  SupabaseClient client,
  String pendingConfirmationId,
) {
  return callRpc<PendingConfirmationCandidateInfo>(
    client,
    'get_pending_confirmation_candidate_info',
    params: {'p_pending_confirmation_id': pendingConfirmationId},
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return PendingConfirmationCandidateInfo(
        displayName: json['display_name'] as String,
        avatarUrl: json['avatar_url'] as String,
        school: SCHOOL.values.byName(json['school'] as String),
        department: json['department'] as String?,
        degreeLevel: DEGREE_LEVEL.values.byName(json['degree_level'] as String),
        reliabilityTier: ReliabilityTier.fromValue(
          json['reliability_tier'] as String?,
        ),
        completedActivityCount: json['completed_activity_count'] as int,
      );
    },
  );
}
