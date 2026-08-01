import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/activity_alert_subscription.dart';
import '../generated/supadart_header.dart' show SCHOOL;
import 'rpc_client.dart';

/// docs/API.md §14.1 — `rpc: subscribe_activity_alert(activity_type_id,
/// school, campus, lookahead_hours)` (v1.27). `lookaheadHours` must be
/// 1–24 (RPC-level `INVALID_INPUT` detail `LOOKAHEAD_HOURS_OUT_OF_RANGE`).
/// Max 5 concurrent active subscriptions per user (`TOO_MANY_ALERT_SUBSCRIPTIONS`).
Future<ActivityAlertSubscription> subscribeActivityAlert(
  SupabaseClient client, {
  required String activityTypeId,
  required SCHOOL school,
  required String campus,
  required int lookaheadHours,
}) {
  return callRpc<ActivityAlertSubscription>(
    client,
    'subscribe_activity_alert',
    params: {
      'p_activity_type_id': activityTypeId,
      'p_school': school.name,
      'p_campus': campus,
      'p_lookahead_hours': lookaheadHours,
    },
    decode: (data) => ActivityAlertSubscription.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §14.2 — `rpc: unsubscribe_activity_alert(subscription_id)`
/// (v1.27). Idempotent — a missing/foreign id is treated as success.
Future<void> unsubscribeActivityAlert(SupabaseClient client, {required String subscriptionId}) {
  return callRpc<void>(
    client,
    'unsubscribe_activity_alert',
    params: {'p_subscription_id': subscriptionId},
    decode: (_) {},
  );
}
