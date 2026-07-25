import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart' show RELIABILITY_EVENT_TYPE;
import 'rpc_client.dart';

class ActivityContactEntry {
  final String userId;
  final String displayName;
  final String avatarUrl;

  /// NOTE: the migration's jsonb_build_object literally names this key
  /// `role` but populates it from `activity_member.status` (JOINED/CANCELLED
  /// — see supabase/migrations/20260724120500_rpc_activity_and_contacts.sql:52),
  /// not from any actual "role" column. Kept as a raw string here rather
  /// than mapped to a generated enum so this footgun is visible at the call
  /// site instead of silently coerced.
  final String status;

  /// null when contacts aren't visible yet (see [ActivityContacts]).
  final ActivityContactDetails? contacts;

  ActivityContactEntry({
    required this.userId,
    required this.displayName,
    required this.avatarUrl,
    required this.status,
    required this.contacts,
  });
}

class ActivityContactDetails {
  final String? contactIg;
  final String? contactLine;
  final String? contactDiscord;

  ActivityContactDetails({this.contactIg, this.contactLine, this.contactDiscord});
}

class ActivityContacts {
  final String activityId;
  final DateTime contactVisibleUntil;
  final List<ActivityContactEntry> members;

  ActivityContacts({
    required this.activityId,
    required this.contactVisibleUntil,
    required this.members,
  });
}

/// docs/API.md §6.2 — `rpc: get_activity_contacts(activity_id)`.
///
/// GAP vs docs/API.md: the doc's §6 error table lists `CONTACT_EXPIRED` and
/// `ACTIVITY_ALREADY_ENDED`. Neither is ever raised — the migration
/// (supabase/migrations/20260724120500_rpc_activity_and_contacts.sql:11-80)
/// always returns 200 with `members[].contacts == null` for members whose
/// contact info isn't visible yet. Callers must branch on `contacts == null`
/// per member, not catch an exception.
Future<ActivityContacts> getActivityContacts(
  SupabaseClient client,
  String activityId,
) {
  return callRpc<ActivityContacts>(
    client,
    'get_activity_contacts',
    params: {'p_activity_id': activityId},
    decode: (data) {
      final json = data as Map<String, dynamic>;
      final members = (json['members'] as List).cast<Map<String, dynamic>>();
      return ActivityContacts(
        activityId: json['activity_id'] as String,
        contactVisibleUntil: DateTime.parse(
          json['contact_visible_until'] as String,
        ),
        members: members.map((m) {
          final contacts = m['contacts'] as Map<String, dynamic>?;
          return ActivityContactEntry(
            userId: m['user_id'] as String,
            displayName: m['display_name'] as String,
            avatarUrl: m['avatar_url'] as String,
            status: m['role'] as String,
            contacts: contacts == null
                ? null
                : ActivityContactDetails(
                    contactIg: contacts['contact_ig'] as String?,
                    contactLine: contacts['contact_line'] as String?,
                    contactDiscord: contacts['contact_discord'] as String?,
                  ),
          );
        }).toList(),
      );
    },
  );
}

class CancelActivityParticipationResult {
  final bool success;
  final RELIABILITY_EVENT_TYPE eventType;
  CancelActivityParticipationResult({
    required this.success,
    required this.eventType,
  });
}

/// docs/API.md §6.3 — `rpc: cancel_activity_participation(activity_id)`.
/// `event_type` reuses the generated `RELIABILITY_EVENT_TYPE` enum — same
/// Postgres type as `user_reliability_event.event_type`.
Future<CancelActivityParticipationResult> cancelActivityParticipation(
  SupabaseClient client,
  String activityId,
) {
  return callRpc<CancelActivityParticipationResult>(
    client,
    'cancel_activity_participation',
    params: {'p_activity_id': activityId},
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return CancelActivityParticipationResult(
        success: json['success'] as bool,
        eventType: RELIABILITY_EVENT_TYPE.values.byName(
          json['event_type'] as String,
        ),
      );
    },
  );
}
