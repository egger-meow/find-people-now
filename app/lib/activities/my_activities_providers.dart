import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/match_request.dart';
import '../generated/supadart_header.dart' show ACTIVITY_STATUS, REQUEST_STATUS;
import '../rpc/match_request_rpc.dart' show decodeMatchRequest;

/// UI_PLAN.md §4 — 依狀態分類的「我的活動」清單。Round 1 只給
/// REQUESTING/PENDING_CONFIRMATION/EXPIRED/CANCELLED 完整卡片，MATCHED/
/// ONGOING/COMPLETED 這輪只證明清單本身能正確撈到、放對分頁，卡片內容留到
/// 之後幾輪（見 my_activities_screen.dart 的 _PlaceholderActivityCard）。
enum MyActivityKind { request, activity }

class MyActivityListItem {
  final MyActivityKind kind;
  final MatchRequest? request;
  final Activity? activity;

  const MyActivityListItem.request(this.request)
      : kind = MyActivityKind.request,
        activity = null;

  const MyActivityListItem.activity(this.activity)
      : kind = MyActivityKind.activity,
        request = null;

  String get id => kind == MyActivityKind.request ? request!.id : activity!.id;

  String get activityTypeId =>
      kind == MyActivityKind.request ? request!.activityTypeId : activity!.activityTypeId;

  DateTime get sortKey =>
      kind == MyActivityKind.request ? request!.createdAt : activity!.createdAt;

  /// 進行中 vs 已結束 兩個分頁（UI_PLAN §4 表格）的分類依據。
  bool get isOngoing {
    if (kind == MyActivityKind.request) {
      return request!.status == REQUEST_STATUS.REQUESTING ||
          request!.status == REQUEST_STATUS.PENDING_CONFIRMATION;
    }
    return activity!.status == ACTIVITY_STATUS.MATCHED ||
        activity!.status == ACTIVITY_STATUS.ONGOING;
  }
}

/// 來源 1：`match_request`（RLS `my_requests_select`：owner 或透過邀請連結
/// 加入的非 owner 成員都看得到自己所屬的那筆——已用 `set local role
/// authenticated` 對本地實例驗證過這條路徑沒有問題，見這輪的探測紀錄）。
///
/// 只查 REQUESTING/PENDING_CONFIRMATION/EXPIRED/CANCELLED：`MATCHED` 之後
/// 這筆 Request 已經衍生出 `activity`，「目前實際階段」改由下面的
/// `activity` 查詢代表，避免同一次配對在清單裡重複出現兩張卡片；`DRAFT`
/// 是尚未送出的半成品表單，不算「我的活動」。
///
/// 刻意不加 `.eq('owner_id', ...)`：那樣會漏掉透過邀請連結加入、非 owner
/// 的 Request，單靠 RLS 收斂才是這裡要的效果（探測時特別驗證過這個
/// 不帶過濾條件的查詢型態）。
final myMatchRequestsProvider = FutureProvider<List<MatchRequest>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return [];
  final client = ref.watch(supabaseClientProvider);
  final rows = await client.from('match_request').select().inFilter('status', [
    'REQUESTING',
    'PENDING_CONFIRMATION',
    'EXPIRED',
    'CANCELLED',
  ]);
  return rows.map(decodeMatchRequest).toList();
});

/// 來源 2：`activity`，透過 `activity_member` embed 查「我是成員的活動」
/// （`my_activities_select`/`my_activity_members_select` RLS，經
/// `fn_is_activity_member` helper 修過遞迴，見 SPEC v1.11.1）。
final myActivitiesFromActivityTableProvider = FutureProvider<List<Activity>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return [];
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('activity_member')
      .select('activity:activity_id(*)')
      .eq('user_id', userId);
  return rows
      .map((r) => r['activity'])
      .whereType<Map<String, dynamic>>()
      .map(Activity.fromJson)
      .toList();
});

/// 合併兩個來源、依 `createdAt` 新到舊排序——畫面依 [MyActivityListItem.isOngoing]
/// 分兩個分頁顯示（UI_PLAN §4）。
final myActivityListProvider = FutureProvider<List<MyActivityListItem>>((ref) async {
  final requests = await ref.watch(myMatchRequestsProvider.future);
  final activities = await ref.watch(myActivitiesFromActivityTableProvider.future);
  final items = [
    for (final r in requests) MyActivityListItem.request(r),
    for (final a in activities) MyActivityListItem.activity(a),
  ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));
  return items;
});

/// 反饋：各處呼叫端一直只單獨 `ref.invalidate(myActivityListProvider)`——但這個
/// provider 只是 `ref.watch(xxx.future)` 组合兩個來源 provider，`invalidate`
/// 只會讓它自己的計算重跑，不會連帶讓被 watch 的 [myMatchRequestsProvider]／
/// [myActivitiesFromActivityTableProvider] 重新查詢；那兩個沒被標成 dirty，
/// 重跑時 `ref.watch(...future)` 直接拿到它們原本沒過期的快取結果，等於整個
/// invalidate 沒有實際效果。曾造成配對成立後等待室顯示「配對成功」（讀的是
/// Realtime stream，永遠新鮮），但「我的活動」清單還是顯示配對前的
/// `等待配對中`——來回點擊變成無限迴圈。統一用這個 helper，一次把三個
/// provider 都標成過期。
void invalidateMyActivityList(WidgetRef ref) {
  ref.invalidate(myMatchRequestsProvider);
  ref.invalidate(myActivitiesFromActivityTableProvider);
  ref.invalidate(myActivityListProvider);
}
