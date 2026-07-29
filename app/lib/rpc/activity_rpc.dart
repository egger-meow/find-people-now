import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/activity_location_option.dart';
import '../generated/activity_location_vote.dart';
import '../generated/activity_meeting_point_update.dart';
import '../generated/activity_member.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL, RELIABILITY_EVENT_TYPE, SCHOOL;
import 'auth_profile_rpc.dart' show ReliabilityTier;
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

class ActivityMemberProfile {
  final String userId;
  final SCHOOL school;
  final String? department;
  final DEGREE_LEVEL degreeLevel;
  final ReliabilityTier reliabilityTier;

  ActivityMemberProfile({
    required this.userId,
    required this.school,
    required this.department,
    required this.degreeLevel,
    required this.reliabilityTier,
  });
}

/// docs/API.md §6.1.1 — `rpc: get_activity_member_profiles(activity_id)`
/// (v1.23). Fills the gap `get_activity_contacts` leaves: that RPC returns
/// `display_name`/`avatar_url`/`contacts` for every member unconditionally,
/// but never `school`/`department`/`degree_level`/reliability tier, and
/// `app_user`'s RLS blocks reading another member's row directly. Callers
/// merge this by `userId` with [getActivityContacts]'s member list — this
/// RPC deliberately does not repeat `display_name`/`avatar_url`/`contacts`.
/// Includes every member regardless of `status` (JOINED/CANCELLED), same as
/// `getActivityContacts`.
Future<List<ActivityMemberProfile>> getActivityMemberProfiles(
  SupabaseClient client,
  String activityId,
) {
  return callRpc<List<ActivityMemberProfile>>(
    client,
    'get_activity_member_profiles',
    params: {'p_activity_id': activityId},
    decode: (data) {
      final list = (data as List).cast<Map<String, dynamic>>();
      return list.map((m) {
        return ActivityMemberProfile(
          userId: m['user_id'] as String,
          school: SCHOOL.values.byName(m['school'] as String),
          department: m['department'] as String?,
          degreeLevel: DEGREE_LEVEL.values.byName(m['degree_level'] as String),
          reliabilityTier: ReliabilityTier.fromValue(m['reliability_tier'] as String?),
        );
      }).toList();
    },
  );
}

/// docs/API.md §6.4 — `rpc: propose_activity_location(activity_id, location_id)`
/// (v1.11). Proposing also casts the caller's own vote for it — a second
/// call for a location someone else already proposed just re-votes, it's not
/// an error (see the migration's `on conflict ... do nothing` handling).
Future<ActivityLocationOption> proposeActivityLocation(
  SupabaseClient client, {
  required String activityId,
  required String locationId,
}) {
  return callRpc<ActivityLocationOption>(
    client,
    'propose_activity_location',
    params: {'p_activity_id': activityId, 'p_location_id': locationId},
    decode: (data) =>
        ActivityLocationOption.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §6.5 — `rpc: vote_activity_location(activity_id, location_id)`
/// (v1.11). One vote per user per activity; calling again with a different
/// `locationId` changes the vote (upsert on `(activity_id, user_id)`).
Future<ActivityLocationVote> voteActivityLocation(
  SupabaseClient client, {
  required String activityId,
  required String locationId,
}) {
  return callRpc<ActivityLocationVote>(
    client,
    'vote_activity_location',
    params: {'p_activity_id': activityId, 'p_location_id': locationId},
    decode: (data) =>
        ActivityLocationVote.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §6.6 — `rpc: update_meeting_point(activity_id, description)`
/// (v1.11.1). Append-only — each call adds a new row, it does not overwrite
/// a previous one. Independent of whether `activity_location_id` is locked;
/// only requires `activity.status in (MATCHED, ONGOING)`. Throws
/// `ApiErrorCode.meetingPointUpdateCooldown` if the caller updated this same
/// activity within the last `app_config.meeting_point_update_cooldown_minutes`.
Future<ActivityMeetingPointUpdate> updateMeetingPoint(
  SupabaseClient client, {
  required String activityId,
  required String description,
}) {
  return callRpc<ActivityMeetingPointUpdate>(
    client,
    'update_meeting_point',
    params: {'p_activity_id': activityId, 'p_description': description},
    decode: (data) =>
        ActivityMeetingPointUpdate.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §6.7 — `rpc: update_meeting_hint(activity_id, hint)`
/// (v1.11.1). Overwrites the caller's own `activity_member.meeting_hint` in
/// place (not append-only, unlike [updateMeetingPoint]). `hint` is capped at
/// 30 characters (RPC-level `INVALID_INPUT` + a DB `CHECK` constraint both
/// enforce this); pass an empty/blank string to clear it.
Future<ActivityMember> updateMeetingHint(
  SupabaseClient client, {
  required String activityId,
  required String hint,
}) {
  return callRpc<ActivityMember>(
    client,
    'update_meeting_hint',
    params: {'p_activity_id': activityId, 'p_hint': hint},
    decode: (data) => ActivityMember.fromJson(data as Map<String, dynamic>),
  );
}
