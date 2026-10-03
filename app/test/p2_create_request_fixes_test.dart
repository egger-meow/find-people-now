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
  id: 'usr-p2-c-1',
  school: SCHOOL.NYCU,
  email: 'test@nycu.edu.tw',
  displayName: '測試小精靈',
  avatarUrl: 'https://avatar/1',
  bio: '測試用個人簡介',
  degreeLevel: DEGREE_LEVEL.UNDERGRAD,
  defaultCampus: '光復',
  createdAt: DateTime(2026),
);

final _testTypes = [
  ActivityType(
    id: 'badminton',
    name: '羽球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 3,
    defaultMaxParticipants: 5,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 1,
    levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
    aliases: const [],
  ),
];

final _fixedNow = DateTime(2026, 9, 23, 13, 0);

class _TestGateway
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
      id: 'req-c-123',
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
      maxParticipants: 5,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
    );
  }
}

Widget _buildApp({required _TestGateway gateway}) {
  return ProviderScope(
    overrides: [
      myActiveRequestProvider.overrideWith((ref) async => null),
      myActiveActivityProvider.overrideWith((ref) async => null),
      activityTypesProvider.overrideWith((ref) async => _testTypes),
      myAppUserProvider.overrideWith((ref) async => _testUser),
      campusOptionsProvider.overrideWith((ref, school) async => ['光復', '交大博愛']),
      myReliabilityProvider.overrideWith(
        (ref) async => MyReliability(
          tier: ReliabilityTier.normal,
          isNewUser: false,
        ),
      ),
      campusDemandsProvider.overrideWith(
        (ref, key) => Stream.value(const <CampusDemandCard>[]),
      ),
      myActiveAlertSubscriptionsProvider.overrideWith(
        (ref) async => const <ActivityAlertSubscription>[],
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: CreateRequestScreen(
        submissionGateway: gateway,
        now: () => _fixedNow,
      ),
    ),
  );
}

void main() {
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('F16 & F18: Bento steps render clean badges, and time chips show hour ranges', (tester) async {
    final gateway = _TestGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway));
    await tester.pumpAndSettle();

    // F16: Step badges 1 and 2 exist without repetitive "步驟 1" labels
    await scrollTo(tester, find.text('活動'));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('步驟 1'), findsNothing);

    await scrollTo(tester, find.text('時間'));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('步驟 2'), findsNothing);

    // F18: Time chips display short hour intervals (e.g. 14:00–18:00)
    expect(find.text('今天 下午'), findsOneWidget);
    expect(find.text('14:00–18:00'), findsOneWidget);
  });

  testWidgets('F17: Downgrade section uses clear user copy and eliminates internal jargon', (tester) async {
    final gateway = _TestGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('人數不足時'));
    expect(find.text('人數不足時'), findsWidgets);
    expect(find.text('降級配對'), findsNothing);
    expect(
      find.text('若截止時未達最多人數，仍可依最少人數彈性成立活動。'),
      findsOneWidget,
    );
  });

  testWidgets('F19: Headcount RangeSlider provides accessible semantics and non-drag fine-tuning flow', (tester) async {
    final gateway = _TestGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway));
    await tester.pumpAndSettle();

    // Tap badminton
    await scrollTo(tester, find.text('羽球'));
    await tester.tap(find.text('羽球'));
    await tester.pumpAndSettle();

    // Scroll to headcount section
    await scrollTo(tester, find.text('人數'));

    // Headcount RangeSlider is present
    expect(find.byType(RangeSlider), findsOneWidget);

    // 1. 驗證讀屏語意節點：包含清楚的最少/最多人數與操作指引
    final semanticsFinder = find.byWidgetPredicate(
      (w) => w is Semantics && (w.properties.label?.contains('人數規模滑桿') == true),
    );
    expect(semanticsFinder, findsOneWidget);
    final semanticsWidget = tester.widget<Semantics>(semanticsFinder);
    expect(semanticsWidget.properties.label, contains('最少'));
    expect(semanticsWidget.properties.label, contains('最多'));
    expect(semanticsWidget.properties.value, contains('人'));

    // 2. 驗證替代調整途徑（非拖曳微調面板）：點擊打開、加減數值、完成後即時更新
    expect(find.text('微調人數（可逐人加減）'), findsOneWidget);
    await tester.tap(find.text('微調人數（可逐人加減）'));
    await tester.pumpAndSettle();

    expect(find.text('微調人數'), findsOneWidget);
    expect(find.text('最少人數'), findsOneWidget);
    expect(find.text('最多人數'), findsOneWidget);

    // 點擊「增加最少人數」
    final increaseMinBtn = find.byTooltip('增加最少人數');
    expect(increaseMinBtn, findsOneWidget);
    await tester.tap(increaseMinBtn);
    await tester.pumpAndSettle();

    // 點擊完成關閉 Sheet
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 驗證首頁滑桿值已由 (2.0, 5.0) 依羽球步長（2人）更新為 (4.0, 5.0)
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.values.start, 4.0);
    expect(slider.values.end, 5.0);
    expect(find.textContaining('4 人'), findsWidgets);
  });

  testWidgets('F20: Confirmation dialog displays helpful outcome note', (tester) async {
    final gateway = _TestGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway));
    await tester.pumpAndSettle();

    // Select badminton
    await tester.scrollUntilVisible(find.text('羽球'), 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('羽球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('羽球'));
    await tester.pumpAndSettle();

    // Select "現在"
    await tester.scrollUntilVisible(find.text('現在'), 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('現在'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('現在'));
    await tester.pumpAndSettle();

    // Submit button
    await tester.tap(find.text('送出，開始找人'));
    await tester.pumpAndSettle();

    // Confirmation dialog appears
    expect(find.text('確認配對條件'), findsOneWidget);
    expect(find.text('確認送出'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // Context note is visible
    expect(find.textContaining('送出後進入等待室，可隨時取消配對'), findsOneWidget);
    expect(find.textContaining('若逾時未滿額將安全結束，不影響信賴紀錄'), findsOneWidget);
  });
}
