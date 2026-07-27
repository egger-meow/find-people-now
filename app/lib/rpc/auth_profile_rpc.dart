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
