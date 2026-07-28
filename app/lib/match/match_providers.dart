import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity_type.dart';
import '../generated/app_user.dart';
import '../generated/match_request.dart';
import '../generated/request_member.dart';
import '../generated/supadart_header.dart' show REQUEST_STATUS, SCHOOL;
import '../rpc/activity_type_rpc.dart';
import '../rpc/auth_profile_rpc.dart';

/// Whether the signed-in user has an `app_user` row yet (`complete_profile`
/// already ran once). Drives the go_router redirect to `/complete-profile`.
/// `.maybeSingle()` over PostgREST, scoped by the existing `own_profile_select`
/// RLS policy (`id = auth.uid()`) — no new grant/policy needed.
final hasProfileProvider = FutureProvider<bool>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return false;
  final client = ref.watch(supabaseClientProvider);
  final row = await client.from('app_user').select('id').eq('id', userId).maybeSingle();
  return row != null;
});

/// UI_PLAN.md §2.1 步驟 1 — 官方預設 + 使用者提案通過的活動類型。
final activityTypesProvider = FutureProvider<List<ActivityType>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  return searchActivityType(client);
});

/// 自己的 `app_user` 列——只有在 [hasProfileProvider] 為 true 之後才有意義。
final myAppUserProvider = FutureProvider<AppUser?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final client = ref.watch(supabaseClientProvider);
  final row = await client.from('app_user').select().eq('id', userId).maybeSingle();
  return row == null ? null : AppUser.fromJson(row);
});

/// UI_PLAN.md §2.1 步驟 3 — MVP 階段每校僅一個校區，選單實質上是自動帶入：
/// 從該校已核准地點反查 distinct campus。
final campusOptionsProvider = FutureProvider.family<List<String>, SCHOOL>((ref, school) async {
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('location')
      .select('campus')
      .eq('school', school.name)
      .eq('status', 'APPROVED');
  final campuses = rows.map((r) => r['campus'] as String).toSet().toList()..sort();
  return campuses;
});

/// UI_PLAN.md §2.2 — New tier 使用者的人數選單 ≤2 人選項要直接 disable，不等
/// 送出才顯示 `NEW_USER_LOW_HEADCOUNT` 錯誤。
final myReliabilityProvider = FutureProvider<MyReliability>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  return getMyReliability(client);
});

/// UI_PLAN.md §2.2 送出前預先攔截：使用者已有 `REQUESTING`/`MATCHED` 中的活動
/// 時，一進配對頁就該直接導去該活動，不重新顯示表單。`match_request.status`
/// 沒有 `ONGOING` 這個值（那是 `activity.status` 的值，見
/// generated/supadart_header.dart 的 REQUEST_STATUS enum）——配對成立
/// (`MATCHED`) 之後衍生出的 `activity` 進行到哪個階段跟 Request 本身無關。
/// Only ever one active row per owner (§6 單一 REQUESTING 唯一索引 — see
/// docs/API.md §10), so `.maybeSingle()` is safe here, not an
/// oversimplification.
final myActiveRequestProvider = FutureProvider<MatchRequest?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('match_request')
      .select()
      .eq('owner_id', userId)
      .inFilter('status', ['REQUESTING', 'MATCHED']);
  if (rows.isEmpty) return null;
  return MatchRequest.fromJson(rows.first);
});

/// UI_PLAN.md §3 技術要求 — Realtime 訂閱單一 Request 的狀態變化，取代靜態
/// 載入/手動刷新。`request_member` 為家族 (family)：等待室以外的畫面不需要它。
final matchRequestStreamProvider = StreamProvider.family<MatchRequest?, String>((ref, requestId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('match_request')
      .stream(primaryKey: ['id'])
      .eq('id', requestId)
      .map((rows) => rows.isEmpty ? null : MatchRequest.fromJson(rows.first));
});

/// 等待室成員頭像列（UI_PLAN §3）背後的資料——即時反應人數變化。
final requestMembersStreamProvider = StreamProvider.family<List<RequestMember>, String>((ref, requestId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('request_member')
      .stream(primaryKey: ['id'])
      .eq('request_id', requestId)
      .map((rows) => rows.map(RequestMember.fromJson).toList());
});

/// REQUESTING 以後（PENDING_CONFIRMATION／MATCHED／ONGOING）不再是等待室的
/// 狀態——等待室畫面看到這些值就該依 UI_PLAN §4 導去對應畫面（本輪只做
/// REQUESTING 這一段，其餘狀態先顯示過渡訊息，見 waiting_room_screen.dart）。
bool isTerminalForWaitingRoom(REQUEST_STATUS status) => status != REQUEST_STATUS.REQUESTING;
