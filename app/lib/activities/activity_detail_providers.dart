import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/activity_location_vote.dart';
import '../generated/activity_meeting_point_update.dart';
import '../generated/completion_report.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart' show ACTIVITY_MEMBER_STATUS, DEGREE_LEVEL, SCHOOL, SKILL_LEVEL;
import '../rpc/activity_rpc.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;

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

/// Arrival Check（v1.24）——只訂閱 `activity_member` 的 `user_id`/`arrived_at`
/// 兩欄變化，不把整個成員名單（[activityMemberRosterProvider]）改成
/// Realtime：後者每次事件都要重新打 `get_activity_contacts`/
/// `get_activity_member_profiles` 兩支 RPC，抵達狀態變化不需要那麼重的刷新，
/// 這裡單獨用一個窄 stream 疊加在既有名單上即可。
final activityArrivalStreamProvider =
    StreamProvider.family<Map<String, DateTime?>, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity_member')
      .stream(primaryKey: ['activity_id', 'user_id'])
      .eq('activity_id', activityId)
      .map((rows) {
        return {
          for (final row in rows)
            row['user_id'] as String:
                row['arrived_at'] == null ? null : DateTime.parse(row['arrived_at'] as String),
        };
      });
});

/// Vibe Tags（v1.28）即時同步給其他成員看——跟 [activityArrivalStreamProvider]
/// 同一種「窄 stream 疊加在既有名單上」手法：只訂閱 `vibe_tags` 這一欄，不把
/// 整個 [activityMemberRosterProvider]（會連帶重打兩支聯絡方式/個資 RPC）改成
/// Realtime。反饋：使用者編輯自己的 vibe tags 後，原本只在自己這端
/// `ref.invalidate(activityMemberRosterProvider(...))`，其他正在看同一個活動
/// 的成員完全不會知道，要等他們自己下拉刷新才看得到。
final activityVibeTagsStreamProvider =
    StreamProvider.family<Map<String, List<String>>, String>((ref, activityId) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('activity_member')
      .stream(primaryKey: ['activity_id', 'user_id'])
      .eq('activity_id', activityId)
      .map((rows) {
        return {
          for (final row in rows)
            row['user_id'] as String: (row['vibe_tags'] as List?)?.cast<String>() ?? const <String>[],
        };
      });
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

/// UI_PLAN.md §4.1 Tab 2「成員」的資料層——合併三個來源，依 `userId` 對齊：
/// 1. `activity_member` 直讀（RLS 已放行同活動成員互看，見
///    `my_activity_members_select`）：`source_request_id`（分組用）+ `status`。
/// 2. `get_activity_contacts`：`display_name`/`avatar_url`（無條件回傳）+
///    `contacts`（依 24h/再約規則決定 null 與否）。
/// 3. `get_activity_member_profiles`（v1.23，`bio` 為 v1.33 新增）：
///    `school`/`department`/`degree_level`/`bio`/可信度等級——`get_activity_contacts`
///    沒有的欄位，`app_user` RLS 又擋掉直讀其他成員，見 SPEC.md v1.23/v1.33。
///    `bio` 供個人檔案卡使用（`activity_detail_screen.dart` 的
///    `_ProfileCardSheet`）。
///
/// 不用 Realtime：成員名單/聯絡方式不像地點投票有「即時得票數」的明確需求
/// （UI_PLAN §4.1 只有 Tab 1 提到即時），下拉刷新已足夠。
class MemberRosterEntry {
  final String userId;
  final String sourceRequestId;
  final ACTIVITY_MEMBER_STATUS status;
  final String displayName;
  final String avatarUrl;
  final ActivityContactDetails? contacts;
  final SCHOOL school;
  final String? department;
  final DEGREE_LEVEL degreeLevel;
  final String bio;
  final ReliabilityTier reliabilityTier;
  final String? meetingHint;
  final DateTime? arrivedAt;
  final List<String> vibeTags;

  /// v1.34/v1.35 — 該成員原始 Request 的程度/讀書目標，來自
  /// `get_activity_member_profiles`（透過 `source_request_id` join 回
  /// `match_request`，見該 RPC 的 migration 註解）。null = 沒指定，或該活動
  /// 類型不適用。
  final SKILL_LEVEL? skillLevel;
  final String? studyTarget;

  MemberRosterEntry({
    required this.userId,
    required this.sourceRequestId,
    required this.status,
    required this.displayName,
    required this.avatarUrl,
    required this.contacts,
    required this.school,
    required this.department,
    required this.degreeLevel,
    required this.bio,
    required this.reliabilityTier,
    required this.meetingHint,
    required this.arrivedAt,
    required this.vibeTags,
    required this.skillLevel,
    required this.studyTarget,
  });

  MemberRosterEntry copyWithArrivedAt(DateTime? arrivedAt) => MemberRosterEntry(
        userId: userId,
        sourceRequestId: sourceRequestId,
        status: status,
        displayName: displayName,
        avatarUrl: avatarUrl,
        contacts: contacts,
        school: school,
        department: department,
        degreeLevel: degreeLevel,
        bio: bio,
        reliabilityTier: reliabilityTier,
        meetingHint: meetingHint,
        arrivedAt: arrivedAt,
        vibeTags: vibeTags,
        skillLevel: skillLevel,
        studyTarget: studyTarget,
      );

  MemberRosterEntry copyWithVibeTags(List<String> vibeTags) => MemberRosterEntry(
        userId: userId,
        sourceRequestId: sourceRequestId,
        status: status,
        displayName: displayName,
        avatarUrl: avatarUrl,
        contacts: contacts,
        school: school,
        department: department,
        degreeLevel: degreeLevel,
        bio: bio,
        reliabilityTier: reliabilityTier,
        meetingHint: meetingHint,
        arrivedAt: arrivedAt,
        vibeTags: vibeTags,
        skillLevel: skillLevel,
        studyTarget: studyTarget,
      );
}

final activityMemberRosterProvider =
    FutureProvider.family<List<MemberRosterEntry>, String>((ref, activityId) async {
  final client = ref.watch(supabaseClientProvider);

  final memberRows = await client.from('activity_member').select().eq('activity_id', activityId);
  final contacts = await getActivityContacts(client, activityId);
  final profiles = await getActivityMemberProfiles(client, activityId);

  final contactByUser = {for (final m in contacts.members) m.userId: m};
  final profileByUser = {for (final p in profiles) p.userId: p};

  return memberRows.map((row) {
    final userId = row['user_id'] as String;
    final contact = contactByUser[userId];
    final profile = profileByUser[userId];
    return MemberRosterEntry(
      userId: userId,
      sourceRequestId: row['source_request_id'] as String,
      status: ACTIVITY_MEMBER_STATUS.values.byName(row['status'] as String),
      displayName: contact?.displayName ?? '（無法載入）',
      avatarUrl: contact?.avatarUrl ?? '',
      contacts: contact?.contacts,
      school: profile?.school ?? SCHOOL.NYCU,
      department: profile?.department,
      degreeLevel: profile?.degreeLevel ?? DEGREE_LEVEL.UNDERGRAD,
      bio: profile?.bio ?? '',
      reliabilityTier: profile?.reliabilityTier ?? ReliabilityTier.unknown,
      meetingHint: row['meeting_hint'] as String?,
      arrivedAt: row['arrived_at'] == null ? null : DateTime.parse(row['arrived_at'] as String),
      vibeTags: (row['vibe_tags'] as List?)?.cast<String>() ?? const [],
      skillLevel: profile?.skillLevel,
      studyTarget: profile?.studyTarget,
    );
  }).toList();
});

/// UI_PLAN.md §6.3「完成確認」——`completion_report` RLS 只放行
/// `reporter_id = auth.uid()`（非歸因原則，見 SPEC §12.1.2），所以這支查詢
/// 天然只會拿到「我自己交過的那份」，用來判斷要不要顯示回報彈窗。
final ownCompletionReportProvider =
    FutureProvider.family<CompletionReport?, String>((ref, activityId) async {
  final client = ref.watch(supabaseClientProvider);
  final rows = await client.from('completion_report').select().eq('activity_id', activityId);
  return rows.isEmpty ? null : CompletionReport.fromJson(rows.first);
});

/// UI_PLAN.md §6.3「再約」——`rematch_vote` RLS 只放行
/// `from_user_id = auth.uid()`（同一非歸因原則，見 SPEC §12.1.2：不暴露對方
/// 是否已經投給我），所以這支查詢天然只回傳「我自己投出去的那些」，用來讓
/// UI 判斷某個對象是否已經按過讚（不代表雙向成立，雙向判定完全交給
/// `rematch_vote` RPC 回傳的 `is_mutual`）。
final ownRematchVotesProvider =
    FutureProvider.family<Set<String>, String>((ref, activityId) async {
  final client = ref.watch(supabaseClientProvider);
  final rows = await client.from('rematch_vote').select().eq('activity_id', activityId);
  return rows.map((r) => r['to_user_id'] as String).toSet();
});
