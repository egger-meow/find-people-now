import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/activity_type.dart';
import '../generated/supadart_header.dart' show SCHOOL;
import 'rpc_client.dart';

class CampusPulseEntry {
  final String activityTypeId;
  final String activityTypeName;
  final int personCount;

  CampusPulseEntry({required this.activityTypeId, required this.activityTypeName, required this.personCount});
}

/// docs/API.md §13.1 — `rpc: get_campus_pulse(school, campus)` (v1.26, headcount fix v1.39).
/// Aggregate-only headcount of people currently in a `REQUESTING` request per
/// activity type — never individual request rows (`match_request`'s RLS
/// deliberately keeps those owner/member-only, see the migration's header
/// comment). Counts `request_member` (status `JOINED`), not `match_request`
/// rows, since one request can already carry multiple invited members.
Future<List<CampusPulseEntry>> getCampusPulse(
  SupabaseClient client, {
  required SCHOOL school,
  required String campus,
}) {
  return callRpc<List<CampusPulseEntry>>(
    client,
    'get_campus_pulse',
    params: {'p_school': school.name, 'p_campus': campus},
    decode: (data) => (data as List)
        .cast<Map<String, dynamic>>()
        .map((row) => CampusPulseEntry(
              activityTypeId: row['activity_type_id'] as String,
              activityTypeName: row['activity_type_name'] as String,
              personCount: row['person_count'] as int,
            ))
        .toList(),
  );
}

/// docs/API.md §2.2 — `rpc: search_activity_type(query)`.
/// `returns setof activity_type` → reuses generated [ActivityType].
Future<List<ActivityType>> searchActivityType(
  SupabaseClient client, {
  String? query,
}) {
  return callRpc<List<ActivityType>>(
    client,
    'search_activity_type',
    params: {'p_query': query},
    decode: (data) => ActivityType.converter(
      (data as List).cast<Map<String, dynamic>>(),
    ),
  );
}

/// docs/API.md §2.3 — `rpc: propose_activity_type(name)`.
///
/// GAP vs docs/API.md: the doc describes a "關鍵字黑名單預檢（命中即回
/// NAME_BLACKLISTED，不落庫）" step before insert. No such check exists in
/// supabase/migrations/20260724120250_rpc_activity_type_and_location.sql:30-64
/// — the function only checks for an empty name (INVALID_INPUT, undocumented)
/// and an exact duplicate name (DUPLICATE_TYPE_NAME). `NAME_BLACKLISTED` is
/// never raised by any migration; do not build client-side handling that
/// expects it until the backend implements it.
Future<ActivityType> proposeActivityType(SupabaseClient client, String name) {
  return callRpc<ActivityType>(
    client,
    'propose_activity_type',
    params: {'p_name': name},
    decode: (data) => ActivityType.fromJson(data as Map<String, dynamic>),
  );
}
