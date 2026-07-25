import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart' show COMPLETION_RESULT;
import 'rpc_client.dart';

class SubmitCompletionReportResult {
  final bool success;
  final bool settled;
  SubmitCompletionReportResult({required this.success, required this.settled});
}

/// docs/API.md §7.1 — `rpc: submit_completion_report(activity_id, result, absent_user_ids?)`.
/// `result` reuses the generated `COMPLETION_RESULT` enum (same Postgres
/// type as `completion_report.result`).
///
/// GAP vs docs/API.md: the doc's §7 error table lists `INVALID_ABSENT_TARGET`
/// ("指認對象不在成員名單") and `ACTIVITY_NOT_ENDED`. Neither is checked in
/// supabase/migrations/20260724120600_rpc_completion_and_settlement.sql:11-105
/// — `absent_user_ids` is inserted with no membership validation, and there
/// is no `activity.status`/`start_time` gate before accepting a report.
Future<SubmitCompletionReportResult> submitCompletionReport(
  SupabaseClient client, {
  required String activityId,
  required COMPLETION_RESULT result,
  List<String> absentUserIds = const [],
}) {
  return callRpc<SubmitCompletionReportResult>(
    client,
    'submit_completion_report',
    params: {
      'p_activity_id': activityId,
      'p_result': result.name,
      'p_absent_user_ids': absentUserIds,
    },
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return SubmitCompletionReportResult(
        success: json['success'] as bool,
        settled: json['settled'] as bool,
      );
    },
  );
}

class RematchVoteResult {
  final bool success;
  final bool isMutual;
  RematchVoteResult({required this.success, required this.isMutual});
}

/// docs/API.md §7.2 — `rpc: rematch_vote(activity_id, to_user_id)`.
///
/// GAP vs docs/API.md: voting for yourself raises `INVALID_INPUT` (detail
/// `CANNOT_VOTE_SELF`) — not declared anywhere in API.md.
Future<RematchVoteResult> rematchVote(
  SupabaseClient client, {
  required String activityId,
  required String toUserId,
}) {
  return callRpc<RematchVoteResult>(
    client,
    'rematch_vote',
    params: {'p_activity_id': activityId, 'p_to_user_id': toUserId},
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return RematchVoteResult(
        success: json['success'] as bool,
        isMutual: json['is_mutual'] as bool,
      );
    },
  );
}
