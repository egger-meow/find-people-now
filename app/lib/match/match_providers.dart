import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/activity_type.dart';
import '../generated/app_user.dart';
import '../generated/match_request.dart';
import '../generated/request_member.dart';
import '../generated/supadart_header.dart' show ACTIVITY_STATUS, REQUEST_STATUS, SCHOOL;
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

/// UI_PLAN.md §2.2 送出前預先攔截：使用者已有 `REQUESTING`/`PENDING_CONFIRMATION`
/// 中的配對流程時，一進配對頁就該直接導去等待室，不重新顯示表單。
///
/// 反饋修復（三台裝置測試，配對業一直卡死/灰掉）：這裡原本把 `MATCHED` 也算
/// 進「有進行中配對」——但 STATE_MACHINE.md 明講「配對成功時 MatchRequest
/// 定格在 MATCHED...之後不再回頭改 MatchRequest」，`match_request.status` 一旦
/// 變成 MATCHED 就永遠停在那裡，即使衍生出的 `activity` 早就 COMPLETED 好幾天
/// 了也一樣。拿它當「現在有沒有進行中配對」的依據，等於使用者只要配對成功
/// 過一次，這裡就永久回傳非 null，永遠被擋在配對頁外面。「現在是否真的有進行
/// 中活動」改由 [myActiveActivityProvider] 直接查 `activity.status`，不能重用
/// 這張表的 MATCHED。
final myActiveRequestProvider = FutureProvider<MatchRequest?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('match_request')
      .select()
      .eq('owner_id', userId)
      .inFilter('status', ['REQUESTING', 'PENDING_CONFIRMATION']);
  if (rows.isEmpty) return null;
  return MatchRequest.fromJson(rows.first);
});

/// 「現在是否有進行中的活動」（`MATCHED`/`ONGOING`）——直接鏡射
/// `create_request` RPC 自己的 `ACTIVE_ACTIVITY_IN_PROGRESS` 檢查
/// （supabase/migrations/20260724120300_rpc_match_request.sql:180-188：
/// `activity_member.status = 'JOINED'` join `activity.status in
/// ('MATCHED','ONGOING')`），讓配對頁能在使用者送出表單「之前」就先擋下來、
/// 顯示清楚的原因，而不是等 RPC 丟錯誤碼才知道。跟 [myActiveRequestProvider]
/// 分開查是因為 `match_request.status` 不會反映活動後續進度（見上方註解）。
final myActiveActivityProvider = FutureProvider<Activity?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('activity_member')
      .select('activity:activity_id(*)')
      .eq('user_id', userId)
      .eq('status', 'JOINED');
  final activities = rows
      .map((r) => r['activity'])
      .whereType<Map<String, dynamic>>()
      .map(Activity.fromJson)
      .where((a) => a.status == ACTIVITY_STATUS.MATCHED || a.status == ACTIVITY_STATUS.ONGOING)
      .toList();
  if (activities.isEmpty) return null;
  activities.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return activities.first;
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
///
/// 依 `id` 去重（`LinkedHashMap` 保留最後一次出現的順序/內容）：反饋回報過
/// 等待室一度出現「兩個我」——實際查過本機 DB，同一個 request 底下並沒有
/// 殘留的重複列（`create_request` 只 insert 一次 owner 列，`join_request_by_token`
/// 對既有列是 `on conflict ... do update`，不會插入第二列），所以不是後端資料
/// 真的重複。比較可能是 `.stream()` 在初始快照與 realtime 事件交錯時，客戶端
/// 曾經短暫拿到同一列兩次——這裡直接防禦性去重，不管實際觸發時機為何都能
/// 保證畫面上每個成員只出現一次。
final requestMembersStreamProvider = StreamProvider.family<List<RequestMember>, String>((ref, requestId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('request_member')
      .stream(primaryKey: ['id'])
      .eq('request_id', requestId)
      .map((rows) {
        final byId = <String, RequestMember>{};
        for (final row in rows) {
          final member = RequestMember.fromJson(row);
          byId[member.id] = member;
        }
        return byId.values.toList();
      });
});

/// 等待室需要顯示該 Request 對應的活動類型名稱（反饋：房間資訊太少）。
/// `activity_type` 表的 RLS 已經有公開 SELECT（status='APPROVED'），直接用
/// PostgREST 查即可。
final activityTypeByIdProvider = FutureProvider.family<ActivityType?, String>((ref, typeId) async {
  final client = ref.watch(supabaseClientProvider);
  final row = await client.from('activity_type').select().eq('id', typeId).maybeSingle();
  return row == null ? null : ActivityType.fromJson(row);
});

/// REQUESTING 以後（PENDING_CONFIRMATION／MATCHED／ONGOING）不再是等待室的
/// 狀態——等待室畫面看到這些值就該依 UI_PLAN §4 導去對應畫面（本輪只做
/// REQUESTING 這一段，其餘狀態先顯示過渡訊息，見 waiting_room_screen.dart）。
bool isTerminalForWaitingRoom(REQUEST_STATUS status) => status != REQUEST_STATUS.REQUESTING;
