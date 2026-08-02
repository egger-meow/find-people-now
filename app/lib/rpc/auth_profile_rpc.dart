import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/app_user.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL;
import 'rpc_client.dart';

/// docs/API.md §1.2 — `rpc: complete_profile(...)`.
/// Returns `to_jsonb(app_user row)` (verified in
/// supabase/migrations/20260724120200_rpc_profile_and_auth.sql:96-100), so
/// the response reuses the supadart-generated [AppUser] type as-is.
Future<AppUser> completeProfile(
  SupabaseClient client, {
  required String displayName,
  required String avatarUrl,
  required DEGREE_LEVEL degreeLevel,
  String? department,
  String? gender,
  String? bio,
  String? contactIg,
  String? contactLine,
  String? contactDiscord,
  String? defaultCampus,
}) {
  return callRpc<AppUser>(
    client,
    'complete_profile',
    params: {
      'p_display_name': displayName,
      'p_avatar_url': avatarUrl,
      'p_degree_level': degreeLevel.name,
      'p_department': department,
      'p_gender': gender,
      'p_bio': bio,
      'p_contact_ig': contactIg,
      'p_contact_line': contactLine,
      'p_contact_discord': contactDiscord,
      // v1.32 — 只有註冊畫面（校區選項 ≥2 個時）會帶這個參數；
      // edit_profile_screen.dart 編輯個人資料重複呼叫時不帶，RPC 端用
      // coalesce 保留原值，不會被這裡的 null 洗掉（見
      // 20260803130100_app_user_default_campus_rpc.sql 註解）。
      'p_default_campus': defaultCampus,
    },
    decode: (data) => AppUser.fromJson(data as Map<String, dynamic>),
  );
}

/// docs/API.md §1.4 — `rpc: get_my_reliability()`.
/// `tier` is Postgres `text` returned by `fn_reliability_tier`
/// (supabase/migrations/20260724120000_init.sql:234-249) — NOT a real
/// Postgres enum type, so supadart could never have generated this even for
/// a table column. Modeled as a Dart enum here anyway per the API contract,
/// with [ReliabilityTier.unknown] as a forward-compat fallback.
enum ReliabilityTier {
  trusted('TRUSTED'),
  normal('NORMAL'),
  newUser('NEW'),
  unknown('__UNKNOWN__');

  final String value;
  const ReliabilityTier(this.value);

  static ReliabilityTier fromValue(String? value) {
    for (final t in ReliabilityTier.values) {
      if (t.value == value) return t;
    }
    return ReliabilityTier.unknown;
  }
}

class MyReliability {
  final ReliabilityTier tier;
  final bool isNewUser;
  MyReliability({required this.tier, required this.isNewUser});
}

Future<MyReliability> getMyReliability(SupabaseClient client) {
  return callRpc<MyReliability>(
    client,
    'get_my_reliability',
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return MyReliability(
        tier: ReliabilityTier.fromValue(json['tier'] as String?),
        isNewUser: json['is_new_user'] as bool,
      );
    },
  );
}

/// docs/API.md §1.7 — `rpc: get_my_badges()` (v1.29). Complements (does not
/// replace) [ReliabilityTier]: badges are earned milestones computed from
/// existing `user_reliability_event`/`rematch_vote`/`match_request` data,
/// never a new persisted score. [AchievementBadge.icon]/[label] are a
/// Dart-side presentation choice — the RPC only returns stable string codes.
enum AchievementBadge {
  firstActivity('FIRST_ACTIVITY', '🌱', '初次參團'),
  punctual('PUNCTUAL', '⚡', '準時好車友'),
  greatCompany('GREAT_COMPANY', '☕', '相談甚歡'),
  enthusiasticOrganizer('ENTHUSIASTIC_ORGANIZER', '🏀', '熱血揪團長');

  final String code;
  final String icon;
  final String label;
  const AchievementBadge(this.code, this.icon, this.label);
}

Future<Set<AchievementBadge>> getMyBadges(SupabaseClient client) {
  return callRpc<Set<AchievementBadge>>(
    client,
    'get_my_badges',
    decode: (data) {
      final rows = (data as List).cast<Map<String, dynamic>>();
      final earnedCodes = rows.where((r) => r['earned'] as bool).map((r) => r['badge_code'] as String).toSet();
      return AchievementBadge.values.where((b) => earnedCodes.contains(b.code)).toSet();
    },
  );
}

/// docs/API.md §1.5 — `rpc: delete_account()`.
/// Only cleans up `public` schema business data and de-identifies the caller's
/// `app_user` row (id unchanged, `deleted_at` set) — it does NOT touch
/// `auth.users`. That step requires the `delete-auth-user` Edge Function (see
/// `lib/account_deletion.dart`), which alone holds the service_role key
/// needed to call the official Admin API.
class DeleteAccountResult {
  final bool success;
  final bool? alreadyDeleted;
  final bool? hadProfile;
  DeleteAccountResult({required this.success, this.alreadyDeleted, this.hadProfile});
}

Future<DeleteAccountResult> deleteAccount(SupabaseClient client) {
  return callRpc<DeleteAccountResult>(
    client,
    'delete_account',
    decode: (data) {
      final json = data as Map<String, dynamic>;
      return DeleteAccountResult(
        success: json['success'] as bool,
        alreadyDeleted: json['already_deleted'] as bool?,
        hadProfile: json['had_profile'] as bool?,
      );
    },
  );
}

/// docs/API.md §1 — `rpc: check_enrollment_reminder(p_degree_level)` (v1.21).
/// Call this with the form's chosen [degreeLevel] right before submitting
/// [completeProfile] during registration; if it returns `true`, show a
/// one-time confirmation dialog (NYCU-only seniority reminder — see
/// SPEC.md §2 point 5) before proceeding with the actual `completeProfile`
/// call. Does not block registration either way.
Future<bool> checkEnrollmentReminder(
  SupabaseClient client, {
  required DEGREE_LEVEL degreeLevel,
}) {
  return callRpc<bool>(
    client,
    'check_enrollment_reminder',
    params: {
      'p_degree_level': degreeLevel.name,
    },
    decode: (data) => data as bool,
  );
}
