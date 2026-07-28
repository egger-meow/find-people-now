import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart' show REPORT_CATEGORY;
import 'rpc_client.dart';

/// docs/API.md — `rpc: submit_report(category, reported_user_id?, reported_activity_id?, detail?)`.
/// At least one of [reportedUserId] / [reportedActivityId] must be non-null.
Future<void> submitReport(
  SupabaseClient client, {
  required REPORT_CATEGORY category,
  String? reportedUserId,
  String? reportedActivityId,
  String? detail,
}) {
  return callRpc<void>(
    client,
    'submit_report',
    params: {
      'p_category': category.name,
      'p_reported_user_id': reportedUserId,
      'p_reported_activity_id': reportedActivityId,
      'p_detail': detail,
    },
    decode: (_) {},
  );
}
