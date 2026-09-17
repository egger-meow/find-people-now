import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_alert_subscription.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/create_request_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/match/widgets/campus_demands_section.dart';
import 'package:find_people_now/match/widgets/pinned_active_status_card.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

final _testUser = AppUser(
  id: 'user-home-1',
  email: 'tester@nycu.edu.tw',
  school: SCHOOL.NYCU,
  displayName: '測試者',
  avatarUrl: 'https://avatar/1',
  bio: '測試自我介紹',
  degreeLevel: DEGREE_LEVEL.UNDERGRAD,
  createdAt: DateTime(2026),
  defaultCampus: '光復',
);

final _testTypes = [
  ActivityType(
    id: 'badminton',
    name: '羽球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 4,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 1,
    levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
    aliases: const [],
  ),
  ActivityType(
    id: 'study',
    name: '讀書',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 6,
    groupSizeStep: 1,
    skillLevelEnabled: false,
    sortOrder: 2,
    levelSystem: LEVEL_SYSTEM.NONE,
    aliases: const [],
  ),
];

final _fixedNow = DateTime(2026, 9, 16, 14, 0);

final _testDemand = CampusDemandCard(
  activityTypeId: 'badminton',
  activityTypeName: '羽球',
  campus: '光復',
  earliestStart: DateTime(2026, 9, 16, 18, 0),
  latestStart: DateTime(2026, 9, 16, 20, 0),
  sportLevel: '8–10 級',
  sportLevelRating: null,
  studyTarget: null,
  minParticipants: 2,
  maxParticipants: 4,
  personCount: 3,
  requestCount: 2,
);

class _TestSubmissionGateway
    implements MatchRequestSubmissionGateway, MatchRequestSubmissionSession {
  final List<String> calls = [];
  final List<Map<String, dynamic>> creates = [];
  final List<String> submittedIds = [];

  @override
  MatchRequestSubmissionSession capture(WidgetRef ref) => this;

  @override
  Future<MatchRequest> create({
    required String activityTypeId,
    required String campus,
    required DateTime earliestStart,
    required DateTime latestStart,
    required int minParticipants,
    int? maxParticipants,
    required bool allowDowngrade,
    required String? sportLevel,
    int? sportLevelRating,
    required String? studyTarget,
  }) async {
    calls.add('create');
    creates.add({
      'activityTypeId': activityTypeId,
      'campus': campus,
      'earliestStart': earliestStart,
      'latestStart': latestStart,
      'minParticipants': minParticipants,
      'maxParticipants': maxParticipants,
      'allowDowngrade': allowDowngrade,
      'sportLevel': sportLevel,
      'sportLevelRating': sportLevelRating,
      'studyTarget': studyTarget,
    });
    return MatchRequest(
      id: 'req-new-123',
      ownerId: _testUser.id,
      activityTypeId: activityTypeId,
      earliestStart: earliestStart,
      latestStart: latestStart,
      flexibleMinutes: 0,
      minParticipants: minParticipants,
      maxParticipants: maxParticipants,
      allowDowngrade: allowDowngrade,
      status: REQUEST_STATUS.DRAFT,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      campus: campus,
      sportLevel: sportLevel,
      sportLevelRating: sportLevelRating,
      studyTarget: studyTarget,
    );
  }

  @override
  Future<MatchRequest> submit(String requestId) async {
    calls.add('submit');
    submittedIds.add(requestId);
    return MatchRequest(
      id: requestId,
      ownerId: _testUser.id,
      activityTypeId: 'badminton',
      earliestStart: _fixedNow,
      latestStart: _fixedNow.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      maxParticipants: 4,
      allowDowngrade: true,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      campus: '光復',
    );
  }
}

List<Override> _overrides({
  MatchRequest? activeRequest,
  Activity? activeActivity,
  List<CampusDemandCard>? demands,
}) => [
  myActiveRequestProvider.overrideWith((ref) async => activeRequest),
  myActiveActivityProvider.overrideWith((ref) async => activeActivity),
  activityTypesProvider.overrideWith((ref) async => _testTypes),
  myAppUserProvider.overrideWith((ref) async => _testUser),
  campusOptionsProvider.overrideWith((ref, school) async => ['光復', '博愛']),
  myReliabilityProvider.overrideWith(
    (ref) async => MyReliability(
      tier: ReliabilityTier.normal,
      isNewUser: false,
    ),
  ),
  campusDemandsProvider.overrideWith(
    (ref, key) => Stream.value(demands ?? [_testDemand]),
  ),
  myActiveAlertSubscriptionsProvider.overrideWith(
    (ref) async => const <ActivityAlertSubscription>[],
  ),
];

Widget _buildHome({
  required _TestSubmissionGateway gateway,
  MatchRequest? activeRequest,
  Activity? activeActivity,
  List<CampusDemandCard>? demands,
  GoRouter? router,
  DateTime Function()? now,
}) {
  final overrides = _overrides(
    activeRequest: activeRequest,
    activeActivity: activeActivity,
    demands: demands,
  );

  if (router != null) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: router,
      ),
    );
  }

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light,
      home: CreateRequestScreen(
        submissionGateway: gateway,
        now: now ?? () => _fixedNow,
      ),
    ),
  );
}

void main() {
  testWidgets('場景 1：無進行中狀態時，正常顯示 CampusDemandsSection 且無置頂狀態卡', (tester) async {
    final gateway = _TestSubmissionGateway();
    await tester.pumpWidget(_buildHome(gateway: gateway));
    await tester.pumpAndSettle();

    // 置頂狀態卡不存在
    expect(find.byType(PinnedActiveStatusCard), findsNothing);

    // 需求卡區塊存在且顯示羽球動態
    expect(find.byType(CampusDemandsSection), findsOneWidget);
    expect(find.text('校園即時揪團動態'), findsOneWidget);
    expect(find.text('羽球'), findsWidgets);
    expect(find.text('8–10 級'), findsOneWidget);

    // 底部送出按鈕正常提示請先選擇活動
    expect(find.text('請先選擇活動'), findsOneWidget);
    expect(find.text('送出，開始找人'), findsOneWidget);
  });

  testWidgets('場景 2：有進行中配對時，置頂顯示等待室狀態卡，需求卡與送出按鈕防呆停用', (tester) async {
    final gateway = _TestSubmissionGateway();
    final activeRequest = MatchRequest(
      id: 'active-req-456',
      ownerId: _testUser.id,
      activityTypeId: 'badminton',
      earliestStart: _fixedNow,
      latestStart: _fixedNow.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      maxParticipants: 4,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      campus: '光復',
    );

    await tester.pumpWidget(_buildHome(gateway: gateway, activeRequest: activeRequest));
    await tester.pumpAndSettle();

    // 置頂狀態卡顯示
    expect(find.byType(PinnedActiveStatusCard), findsOneWidget);
    expect(find.text('你正在配對中'), findsOneWidget);
    expect(find.text('前往等待室'), findsOneWidget);

    // 底部按鈕與提示被鎖定
    expect(find.text('你已有進行中的配對，請先前往等待室或取消後再發起新配對'), findsOneWidget);
    expect(find.text('已在配對等待室中'), findsOneWidget);

    // 點擊需求卡開啟詳情 Sheet，確認「以相容條件加入配對」停用
    await tester.tap(find.byType(CampusDemandCardWidget));
    await tester.pumpAndSettle();

    expect(find.text('匿名活動需求確認'), findsOneWidget);
    expect(find.text('你已在配對等待室中，無法同時加入其他活動'), findsOneWidget);

    // 驗證「以相容條件加入配對」按鈕不可點擊
    final participateButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '以相容條件加入配對'),
    );
    expect(participateButton.onPressed, isNull);
  });

  testWidgets('場景 3：有進行中活動時，置頂顯示活動狀態卡，送出按鈕防呆鎖定', (tester) async {
    final gateway = _TestSubmissionGateway();
    final activeActivity = Activity(
      id: 'active-act-789',
      activityTypeId: 'badminton',
      startTime: _fixedNow,
      estimatedEndTime: _fixedNow.add(const Duration(hours: 2)),
      status: ACTIVITY_STATUS.MATCHED,
      contactVisibleUntil: _fixedNow.add(const Duration(hours: 3)),
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      campus: '光復',
    );

    await tester.pumpWidget(_buildHome(gateway: gateway, activeActivity: activeActivity));
    await tester.pumpAndSettle();

    // 置頂狀態卡顯示活動中
    expect(find.byType(PinnedActiveStatusCard), findsOneWidget);
    expect(find.text('你目前有進行中的活動'), findsOneWidget);
    expect(find.text('前往活動房間'), findsOneWidget);

    // 底部按鈕顯示鎖定
    expect(find.text('你目前有進行中的活動，請先前往活動或結束後再發起新配對'), findsOneWidget);
  });

  testWidgets('場景 4：點擊需求卡「調整條件後發起」，成功預填表單並滾動定位', (tester) async {
    final gateway = _TestSubmissionGateway();
    await tester.pumpWidget(_buildHome(gateway: gateway));
    await tester.pumpAndSettle();

    // 點擊卡片彈出 Sheet
    await tester.tap(find.byType(CampusDemandCardWidget));
    await tester.pumpAndSettle();

    expect(find.text('匿名活動需求確認'), findsOneWidget);

    // 點擊「調整條件後發起」
    await tester.tap(find.textContaining('調整條件後發起'));
    await tester.pumpAndSettle();

    // Sheet 關閉
    expect(find.text('匿名活動需求確認'), findsNothing);

    // 提示 SnackBar 出現
    expect(find.textContaining('已為你預填「羽球」的條件'), findsOneWidget);

    // 驗證羽球已被選中（羽球實力區塊出現）
    expect(find.text('羽球實力'), findsOneWidget);
    expect(find.text('8–10 級'), findsWidgets);
  });

  testWidgets('場景 5：點擊需求卡「以相容條件加入配對」，直接呼叫 gateway.create 與 submit 建立配對並導航', (tester) async {
    final gateway = _TestSubmissionGateway();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => CreateRequestScreen(
            submissionGateway: gateway,
            now: () => _fixedNow,
          ),
        ),
        GoRoute(
          path: '/waiting-room/:id',
          builder: (context, state) =>
              Scaffold(body: Text('進入等待室：${state.pathParameters['id']}')),
        ),
      ],
    );

    await tester.pumpWidget(_buildHome(gateway: gateway, router: router));
    await tester.pumpAndSettle();

    // 點擊需求卡彈出 Sheet
    await tester.tap(find.byType(CampusDemandCardWidget));
    await tester.pumpAndSettle();

    // 點擊「以相容條件加入配對」
    await tester.tap(find.text('以相容條件加入配對'));
    await tester.pumpAndSettle();


    // 驗證 gateway 呼叫
    expect(gateway.calls, ['create', 'submit']);
    expect(gateway.submittedIds, ['req-new-123']);
    final created = gateway.creates.single;
    expect(created['activityTypeId'], 'badminton');
    expect(created['campus'], '光復');
    expect(created['allowDowngrade'], isTrue);
    expect(created['sportLevel'], '8–10 級');

    // 驗證導航至等待室
    expect(find.text('進入等待室：req-new-123'), findsOneWidget);
  });

  testWidgets('場景 6：需求卡最早時間已過但尚未過期，加入時最早時間推進至當前時間 now()', (tester) async {
    final gateway = _TestSubmissionGateway();
    // 需求區間：18:00–20:00，當前時間：18:30（最早時間已過 30 分鐘）
    final currentNow = DateTime(2026, 9, 16, 18, 30);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => CreateRequestScreen(
            submissionGateway: gateway,
            now: () => currentNow,
          ),
        ),
        GoRoute(
          path: '/waiting-room/:id',
          builder: (context, state) =>
              Scaffold(body: Text('進入等待室：${state.pathParameters['id']}')),
        ),
      ],
    );

    await tester.pumpWidget(_buildHome(
      gateway: gateway,
      router: router,
      now: () => currentNow,
    ));
    await tester.pumpAndSettle();

    // 點擊需求卡彈出 Sheet
    await tester.tap(find.byType(CampusDemandCardWidget));
    await tester.pumpAndSettle();

    // 點擊「以相容條件加入配對」
    await tester.tap(find.text('以相容條件加入配對'));
    await tester.pumpAndSettle();

    // 驗證送出的 earliestStart 被推進到 currentNow (18:30)，而非原先的 18:00
    expect(gateway.calls, ['create', 'submit']);
    final created = gateway.creates.single;
    expect(created['earliestStart'], currentNow.toUtc());
    expect(created['latestStart'], DateTime(2026, 9, 16, 20, 0).toUtc());
  });

  testWidgets('場景 7：需求卡已過期時，一鍵加入被阻擋並提示錯誤', (tester) async {
    final gateway = _TestSubmissionGateway();
    // 需求區間：18:00–20:00，當前時間：20:30（已完全過期）
    final expiredNow = DateTime(2026, 9, 16, 20, 30);

    await tester.pumpWidget(_buildHome(
      gateway: gateway,
      now: () => expiredNow,
    ));
    await tester.pumpAndSettle();

    // 點擊需求卡彈出 Sheet
    await tester.tap(find.byType(CampusDemandCardWidget));
    await tester.pumpAndSettle();

    // 點擊「以相容條件加入配對」
    await tester.tap(find.text('以相容條件加入配對'));
    await tester.pumpAndSettle();


    // 驗證未呼叫 gateway 且出現錯誤提示
    expect(gateway.calls, isEmpty);
    expect(find.textContaining('此需求的時間區間已過期，無法加入'), findsOneWidget);
  });
}

