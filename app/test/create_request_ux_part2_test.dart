import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/generated/activity_alert_subscription.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/create_request_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

final _testUser = AppUser(
  id: 'user-ux-part2',
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
    defaultMinParticipants: 3,
    defaultMaxParticipants: 4,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 1,
    levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
    aliases: const [],
  ),
  ActivityType(
    id: 'basketball',
    name: '籃球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 4,
    defaultMaxParticipants: 10,
    groupSizeStep: 2,
    skillLevelEnabled: true,
    sortOrder: 2,
    levelSystem: LEVEL_SYSTEM.BASKETBALL_INTENSITY,
    aliases: const [],
  ),
];

final _fixedNow = DateTime(2026, 9, 23, 14, 0);

class _MockSubmissionGateway
    implements MatchRequestSubmissionGateway, MatchRequestSubmissionSession {
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
    String? sportLevel,
    int? sportLevelRating,
    String? studyTarget,
  }) async {
    return MatchRequest(
      id: 'req-part2-123',
      ownerId: _testUser.id,
      activityTypeId: activityTypeId,
      campus: campus,
      earliestStart: earliestStart,
      latestStart: latestStart,
      flexibleMinutes: 0,
      minParticipants: minParticipants,
      maxParticipants: maxParticipants,
      allowDowngrade: allowDowngrade,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      sportLevel: sportLevel,
      sportLevelRating: sportLevelRating,
      studyTarget: studyTarget,
    );
  }

  @override
  Future<MatchRequest> submit(String requestId) async {
    return MatchRequest(
      id: requestId,
      ownerId: _testUser.id,
      activityTypeId: 'badminton',
      campus: '光復',
      earliestStart: _fixedNow,
      latestStart: _fixedNow.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 3,
      maxParticipants: 4,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
    );
  }
}

Widget _buildTestApp({
  required MatchRequestSubmissionGateway gateway,
  bool isNewUser = false,
  DateTime Function()? now,
}) {
  return ProviderScope(
    overrides: [
      myActiveRequestProvider.overrideWith((ref) async => null),
      myActiveActivityProvider.overrideWith((ref) async => null),
      activityTypesProvider.overrideWith((ref) async => _testTypes),
      myAppUserProvider.overrideWith((ref) async => _testUser),
      campusOptionsProvider.overrideWith((ref, school) async => ['光復', '交大博愛']),
      myReliabilityProvider.overrideWith(
        (ref) async =>
            MyReliability(tier: ReliabilityTier.normal, isNewUser: isNewUser),
      ),
      campusDemandsProvider.overrideWith(
        (ref, key) => Stream.value(const <CampusDemandCard>[]),
      ),
      myActiveAlertSubscriptionsProvider.overrideWith(
        (ref) async => const <ActivityAlertSubscription>[],
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light.copyWith(platform: TargetPlatform.iOS),
      home: Scaffold(
        body: CreateRequestScreen(
          submissionGateway: gateway,
          now: now ?? () => _fixedNow,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('選取活動類型後頁面 scroll offset 維持不變（不自動跳至下一區）', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('羽球'),
      150,
      scrollable: scrollable,
    );
    final initialOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;

    // 點選羽球
    await tester.tap(find.text('羽球'));
    await tester.pumpAndSettle();

    final afterTapOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(afterTapOffset, equals(initialOffset));
  });

  testWidgets('320px 窄螢幕下時間範圍卡與截止時間不產生水平 overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    // 滾動並點選羽球
    await tester.scrollUntilVisible(
      find.text('羽球'),
      150,
      scrollable: scrollable,
    );
    await tester.tap(find.text('羽球'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 滾動並點選「現在」時段
    await tester.scrollUntilVisible(
      find.text('現在'),
      150,
      scrollable: scrollable,
    );
    await tester.tap(find.text('現在'));
    await tester.pumpAndSettle();

    // 驗證時間顯示文字包含「可開始時段」與「配對截止」
    expect(find.textContaining('可開始時段：'), findsOneWidget);
    expect(find.textContaining('配對截止：'), findsOneWidget);

    // 驗證沒有任何 Overflow 異常
    expect(tester.takeException(), isNull);
  });

  testWidgets('新用戶在雙端滑桿中限制不可發起 2 人以下場次並顯示提醒文字', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway, isNewUser: true));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    // 滾動並點選羽球
    await tester.scrollUntilVisible(
      find.text('羽球'),
      150,
      scrollable: scrollable,
    );
    await tester.tap(find.text('羽球'));
    await tester.pumpAndSettle();

    // 滾動至提示文字
    final hintFinder = find.text('新用戶需要先完成一次活動、建立信譽後，才能發起 2 人以下的小型場次');
    await tester.scrollUntilVisible(hintFinder, 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    expect(hintFinder, findsOneWidget);
    expect(find.byType(RangeSlider), findsOneWidget);

    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.values.start, greaterThanOrEqualTo(3.0));
    expect(slider.semanticFormatterCallback?.call(4), '4 人');
  });
}
