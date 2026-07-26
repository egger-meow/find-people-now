import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/location.dart';
import '../generated/supadart_header.dart';
import 'rpc_client.dart';

/// docs/API.md §2.5 — `rpc: propose_location(name, school)` (v1.10).
///
/// Mirrors `proposeActivityType` (same PENDING-then-admin-review flow), but
/// deliberately has no client-side blacklist handling to mirror either —
/// unlike `propose_activity_type`, this endpoint's docs never promised a
/// keyword precheck in the first place (see RPC_COVERAGE.md's v1.10 note for
/// why one wasn't added).
Future<Location> proposeLocation(
  SupabaseClient client, {
  required String name,
  required SCHOOL school,
}) {
  return callRpc<Location>(
    client,
    'propose_location',
    params: {'p_name': name, 'p_school': school.name},
    decode: (data) => Location.fromJson(data as Map<String, dynamic>),
  );
}
