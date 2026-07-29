import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/activity_location_vote.dart';
import '../generated/activity_meeting_point_update.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart' show SCHOOL;

/// UI_PLAN.md §4.1「地點」分頁籤的資料層——單一活動的詳情，family 以
/// `activityId` 區分，避免跟「我的活動」清單層（[myActivityListProvider]）
/// 混在一起。
///
/// 活動本身與投票/提案都用 Realtime `.stream()`（非手動刷新的
/// FutureProvider）：UI_PLAN §4.1 明講地點投票要「即時得票數」，且本專案已有
/// 等待室（match_providers.dart）先例，不算引入新架構。
final activityStreamProvider = StreamProvider.family<Activity?, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity')
      .stream(primaryKey: ['id'])
      .eq('id', activityId)
      .map((rows) => rows.isEmpty ? null : Activity.fromJson(rows.first));
});

final activityLocationOptionsStreamProvider =
    StreamProvider.family<List<ActivityLocationOption>, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity_location_option')
      .stream(primaryKey: ['id'])
      .eq('activity_id', activityId)
      .map((rows) => rows.map(ActivityLocationOption.fromJson).toList());
});

final activityLocationVotesStreamProvider =
    StreamProvider.family<List<ActivityLocationVote>, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity_location_vote')
      .stream(primaryKey: ['activity_id', 'user_id'])
      .eq('activity_id', activityId)
      .map((rows) => rows.map(ActivityLocationVote.fromJson).toList());
});

/// 提案候選地點的選單來源，也用來把 `activity_location_option.location_id`
/// 對應回地點名稱顯示——`propose_activity_location` RPC 本身就限定候選地點
/// 必須是 `(school, campus)` 範圍內的 `APPROVED` 地點（見
/// supabase/migrations/20260724121500_campus_scope_rpc.sql:443-447），所以
/// 這份清單保證涵蓋所有已出現的候選，不會漏掉。
final approvedLocationsProvider =
    FutureProvider.family<List<Location>, (SCHOOL, String)>((ref, key) async {
  final (school, campus) = key;
  final client = ref.watch(supabaseClientProvider);
  final rows = await client
      .from('location')
      .select()
      .eq('school', school.name)
      .eq('campus', campus)
      .eq('status', 'APPROVED');
  return rows.map(Location.fromJson).toList();
});

/// 集合地點更新紀錄（append-only，見 `update_meeting_point` 註解）——新到舊
/// 排序，畫面只需要顯示最新一筆＋歷史。
final activityMeetingPointUpdatesStreamProvider =
    StreamProvider.family<List<ActivityMeetingPointUpdate>, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity_meeting_point_update')
      .stream(primaryKey: ['id'])
      .eq('activity_id', activityId)
      .map((rows) {
        final list = rows.map(ActivityMeetingPointUpdate.fromJson).toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list;
      });
});
