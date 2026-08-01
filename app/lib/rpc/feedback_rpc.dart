import 'package:supabase_flutter/supabase_flutter.dart';

// `Feedback` collides with package:flutter/material.dart's own Feedback
// widget (haptic/audio feedback wrapper) — same reason notification.dart is
// imported `as generated` in notifications_screen.dart.
import '../generated/feedback.dart' as generated;
import 'rpc_client.dart';

/// docs/API.md §12.1 — `rpc: submit_feedback(message, activity_id?, app_version?, device_info?)`
/// (v1.25). This is the durable half of the flow: the row exists regardless
/// of whether the follow-up email send ([sendFeedbackEmail]) succeeds.
Future<generated.Feedback> submitFeedback(
  SupabaseClient client, {
  required String message,
  String? activityId,
  String? appVersion,
  String? deviceInfo,
}) {
  return callRpc<generated.Feedback>(
    client,
    'submit_feedback',
    params: {
      'p_message': message,
      'p_activity_id': activityId,
      'p_app_version': appVersion,
      'p_device_info': deviceInfo,
    },
    decode: (data) => generated.Feedback.fromJson(data as Map<String, dynamic>),
  );
}

/// Best-effort: invokes the `send-feedback-email` Edge Function (the only
/// place holding the Resend API key, see that function's header comment).
/// Returns false on any failure — callers must treat [submitFeedback]
/// succeeding as the actual "feedback received" outcome, same pattern as
/// account_deletion.dart's `_invokeDeleteAuthUserWithRetry` treats the
/// Edge Function call as a secondary, non-blocking step.
Future<bool> sendFeedbackEmail(SupabaseClient client, {required String feedbackId}) async {
  try {
    await client.functions.invoke('send-feedback-email', body: {'feedback_id': feedbackId});
    return true;
  } catch (_) {
    return false;
  }
}
