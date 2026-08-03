import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/match_request.dart';
import '../generated/supadart_header.dart' show SKILL_LEVEL;
import 'rpc_client.dart';

/// Works around a supadart codegen gap (v1.34): `RPC_COVERAGE.md`'s
/// "Table-generation notes" already documents that `fromJson()` substitutes a
/// fabricated default instead of throwing for a NOT NULL column that comes
/// back null — the same `TheEnum.values.first` fallback template turns out to
/// also fire for *nullable* enum columns like `skill_level` (null = wildcard,
/// the common case), silently turning "unspecified" into
/// `SKILL_LEVEL.BEGINNER` (the first enum value) instead of real `null`.
/// Every `MatchRequest.fromJson(...)` call site in the app must go through
/// this instead of the raw generated factory.
MatchRequest decodeMatchRequest(Map<String, dynamic> json) {
  final request = MatchRequest.fromJson(json);
  return json['skill_level'] == null ? request.copyWith(skillLevel: null) : request;
}

/// docs/API.md §3.1 — `rpc: create_request(...)`.
/// min/max participants counts include the owner (see API.md §3.1 note ①).
///
/// `campus` (v1.11) replaces the old `campusLocationId` param — it's now a
/// Matching Scope (free-text `location.campus` value within the caller's own
/// `school`), not a precise location FK. The precise Activity Location is
/// decided post-match via voting (see `activity_location_rpc.dart`).
///
/// `earliestStart`/`latestStart` (v1.16) replace the old `bucket` enum param —
/// SPEC.md §4 always intended time buckets ("now" / "tonight" / etc.) as a
/// UI-layer convenience that gets converted to concrete timestamps before
/// hitting the backend; the caller is responsible for that conversion now.
/// The backend only validates the resulting range (`WINDOW_EXCEEDS_24H`,
/// `INVALID_INPUT` for an inverted or already-past window).
///
/// `skillLevel` (v1.34) only matters when the chosen activity type has
/// `skill_level_enabled = true`; the backend silently forces it to null
/// otherwise, so callers don't need to check the flag before passing it.
/// `studyTarget` (v1.35) similarly only matters for the fixed 讀書 activity
/// type — pass the user's raw input, the backend computes the normalized
/// comparison column itself (see `fn_normalize_study_target`).
Future<MatchRequest> createRequest(
  SupabaseClient client, {
  required String activityTypeId,
  required String campus,
  required DateTime earliestStart,
  required DateTime latestStart,
  required int minParticipants,
  int? maxParticipants,
  bool allowDowngrade = false,
  SKILL_LEVEL? skillLevel,
  String? studyTarget,
}) {
  return callRpc<MatchRequest>(
    client,
    'create_request',
    params: {
      'p_activity_type_id': activityTypeId,
      'p_campus': campus,
      'p_earliest_start': earliestStart.toUtc().toIso8601String(),
      'p_latest_start': latestStart.toUtc().toIso8601String(),
      'p_min_participants': minParticipants,
      'p_max_participants': maxParticipants,
      'p_allow_downgrade': allowDowngrade,
      'p_skill_level': skillLevel?.name,
      'p_study_target': studyTarget,
    },
    decode: (data) => decodeMatchRequest(data as Map<String, dynamic>),
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
    decode: (data) => decodeMatchRequest(data as Map<String, dynamic>),
  );
}

/// docs/API.md §3.3 — `rpc: cancel_request(request_id)`.
Future<MatchRequest> cancelRequest(SupabaseClient client, String requestId) {
  return callRpc<MatchRequest>(
    client,
    'cancel_request',
    params: {'p_request_id': requestId},
    decode: (data) => decodeMatchRequest(data as Map<String, dynamic>),
  );
}

// NOTE: docs/API.md §3.4 `join_request(request_id)` was removed from
// API.md — see the CHANGELOG note added there. No UI path ever calls a
// non-token join (the only invite mechanism is `join_request_by_token`,
// §3.8); this wasn't a missing implementation, it was design leftover from
// before invite tokens existed. No wrapper is written for it; calling
// `client.rpc('join_request', ...)` against this backend will fail with
// PostgREST's function-not-found error, not one of the ApiErrorCode values.
// See RPC_COVERAGE.md.

/// docs/API.md §3.5 — `rpc: leave_request(request_id)`.
/// Implemented in supabase/migrations/20260724121000_rpc_leave_request.sql —
/// previously documented but not implemented at all (see RPC_COVERAGE.md).
/// Non-owner members only: the owner gets `FORBIDDEN` (detail
/// `OWNER_CANNOT_LEAVE_USE_CANCEL_REQUEST`) and must use [cancelRequest]
/// instead, since a Request can't be left without an owner. Only valid
/// before a match (`DRAFT`/`REQUESTING`/`PENDING_CONFIRMATION`) — after
/// that, leaving is handled on the Activity side via
/// `cancel_activity_participation` (§6.3), matching the two-state-diagram
/// boundary API.md §9 documents. Leaving before a match records no
/// Reliability event (API.md §3.5).
Future<MatchRequest> leaveRequest(SupabaseClient client, String requestId) {
  return callRpc<MatchRequest>(
    client,
    'leave_request',
    params: {'p_request_id': requestId},
    decode: (data) => decodeMatchRequest(data as Map<String, dynamic>),
  );
}

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
    decode: (data) => decodeMatchRequest(data as Map<String, dynamic>),
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
