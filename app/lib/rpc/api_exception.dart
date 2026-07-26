/// Error codes actually thrown by the RPCs wrapped in `lib/rpc/`.
///
/// docs/API.md documents error codes as free-form strings inside
/// `raise exception using message = '<CODE>'` (see API.md §0) — Postgres has
/// no real enum type backing them, so a Dart `enum` here is a wrapper-layer
/// choice, not a codegen fact. [unknown] exists so a future/renamed code
/// from the DB never crashes the client; it carries the raw string through.
///
/// IMPORTANT: this list reflects what the migrations under supabase/migrations
/// actually raise as of 2026-07-26, cross-checked function-by-function against
/// docs/API.md. Several codes documented in API.md are never raised by any
/// migration — see RPC_COVERAGE.md for the full discrepancy list. Do not
/// add a code here just because API.md mentions it; add it when a migration
/// actually raises it.
enum ApiErrorCode {
  unauthorized('UNAUTHORIZED'),
  userSuspended('USER_SUSPENDED'),
  profileIncomplete('PROFILE_INCOMPLETE'),
  degreeLevelRequired('DEGREE_LEVEL_REQUIRED'),
  noContactMethod('NO_CONTACT_METHOD'),
  invalidEmailDomain('INVALID_EMAIL_DOMAIN'),
  duplicateTypeName('DUPLICATE_TYPE_NAME'),
  invalidInput('INVALID_INPUT'),
  invalidMinParticipants('INVALID_MIN_PARTICIPANTS'),
  invalidMaxParticipants('INVALID_MAX_PARTICIPANTS'),
  invalidGroupSizeOption('INVALID_GROUP_SIZE_OPTION'),
  schoolLocationMismatch('SCHOOL_LOCATION_MISMATCH'),
  notFound('NOT_FOUND'),
  requestNotOpen('REQUEST_NOT_OPEN'),
  activeActivityInProgress('ACTIVE_ACTIVITY_IN_PROGRESS'),
  requestCooldownActive('REQUEST_COOLDOWN_ACTIVE'),
  alreadyRequesting('ALREADY_REQUESTING'),
  windowExceeds24h('WINDOW_EXCEEDS_24H'),
  newUserLowHeadcount('NEW_USER_LOW_HEADCOUNT'),
  inviteLinkExpired('INVITE_LINK_EXPIRED'),
  requestFull('REQUEST_FULL'),
  confirmationWindowClosed('CONFIRMATION_WINDOW_CLOSED'),
  forbidden('FORBIDDEN'),
  notActivityMember('NOT_ACTIVITY_MEMBER'),
  alreadyReported('ALREADY_REPORTED'),
  consentWindowClosed('CONSENT_WINDOW_CLOSED'),
  alreadyResponded('ALREADY_RESPONDED'),
  unknown('__UNKNOWN__');

  final String code;
  const ApiErrorCode(this.code);

  static ApiErrorCode fromCode(String? code) {
    if (code == null) return ApiErrorCode.unknown;
    for (final value in ApiErrorCode.values) {
      if (value.code == code) return value;
    }
    return ApiErrorCode.unknown;
  }
}

/// Thrown by every function in `lib/rpc/` in place of the raw
/// [PostgrestException] — [code] is parsed from `PostgrestException.message`
/// per API.md §0 ("PostgREST 會將其映射到回應 JSON 的 message 欄位").
class ApiException implements Exception {
  final ApiErrorCode code;
  final String rawMessage;
  final String? detail;

  ApiException({required this.code, required this.rawMessage, this.detail});

  @override
  String toString() =>
      'ApiException(${code.name}: $rawMessage${detail != null ? ', detail: $detail' : ''})';
}
