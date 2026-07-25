import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/activity_type.dart';
import 'rpc_client.dart';

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
