import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/match_request.dart';
import 'rpc_client.dart';

/// `p_bucket` in docs/API.md §3.1 — Postgres param is plain `text` (validated
/// by an if/elsif chain in create_request, not a DB enum — see
/// supabase/migrations/20260724120300_rpc_match_request.sql:85-99), so this
/// Dart enum exists purely as an API-contract convenience, not a codegen fact.
// ignore: constant_identifier_names
enum RequestBucket { NOW, TODAY, TONIGHT, TOMORROW_AM }

/// docs/API.md §3.1 — `rpc: create_request(...)`.
/// min/max participants counts include the owner (see API.md §3.1 note ①).
Future<MatchRequest> createRequest(
  SupabaseClient client, {
  required String activityTypeId,
  required String campusLocationId,
  required RequestBucket bucket,
  required int minParticipants,
  int? maxParticipants,
  bool allowDowngrade = false,
}) {
  return callRpc<MatchRequest>(
    client,
    'create_request',
    params: {
      'p_activity_type_id': activityTypeId,
      'p_campus_location_id': campusLocationId,
      'p_bucket': bucket.name,
      'p_min_participants': minParticipants,
      'p_max_participants': maxParticipants,
      'p_allow_downgrade': allowDowngrade,
    },
    decode: (data) => MatchRequest.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §3.2 — `rpc: submit_request(request_id)`.
/// Validation order is fixed (see the comment block above `submit_request` in
/// the migration) and was verified to match API.md §3.2 exactly.
Future<MatchRequest> submitRequest(SupabaseClient client, String requestId) {
  return callRpc<MatchRequest>(
    client,
    'submit_request',
    params: {'p_request_id': requestId},
    decode: (data) => MatchRequest.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §3.3 — `rpc: cancel_request(request_id)`.
Future<MatchRequest> cancelRequest(SupabaseClient client, String requestId) {
  return callRpc<MatchRequest>(
    client,
    'cancel_request',
    params: {'p_request_id': requestId},
    decode: (data) => MatchRequest.fromJson(data as Map<String, dynamic>),
  );
}

// NOTE: docs/API.md §3.4 `join_request(request_id)` and §3.5
// `leave_request(request_id)` are documented but have NO corresponding
// `create or replace function` anywhere under supabase/migrations/ — grepped
// the full migrations directory, no match. Only `join_request_by_token`
// (§3.8) exists. No wrapper is written for them; calling
// `client.rpc('join_request', ...)` against this backend will fail with
// PostgREST's function-not-found error, not one of the ApiErrorCode values.
// See RPC_COVERAGE.md.

/// docs/API.md §3.7 — `rpc: get_or_create_invite_link(request_id)`.
Future<String> getOrCreateInviteLink(SupabaseClient client, String requestId) {
  return callRpc<String>(
    client,
    'get_or_create_invite_link',
    params: {'p_request_id': requestId},
    decode: (data) => data as String,
  );
}

/// docs/API.md §3.8 — `rpc: join_request_by_token(invite_token)`.
///
/// GAP vs docs/API.md: the doc's §3 error table lists `INVITE_LINK_REVOKED`
/// as distinct from `INVITE_LINK_EXPIRED`. The migration
/// (20260724120300_rpc_match_request.sql:307-368) only ever raises
/// `INVITE_LINK_EXPIRED` — for a missing token, a revoked token, AND an
/// expired token alike (single `where ... and revoked_at is null` filter,
/// one raise site). `INVITE_LINK_REVOKED` is never thrown by this backend.
Future<MatchRequest> joinRequestByToken(
  SupabaseClient client,
  String inviteToken,
) {
  return callRpc<MatchRequest>(
    client,
    'join_request_by_token',
    params: {'p_invite_token': inviteToken},
    decode: (data) => MatchRequest.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §3.9 — `rpc: revoke_invite_link(request_id)`.
Future<bool> revokeInviteLink(SupabaseClient client, String requestId) {
  return callRpc<bool>(
    client,
    'revoke_invite_link',
    params: {'p_request_id': requestId},
    decode: (data) => data as bool,
  );
}
