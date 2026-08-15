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
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_section.dart';

final _testTypes = <ActivityType>[
  ActivityType(
    id: 'basketball',
    name: '籃球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 10,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 10,
    levelSystem: LEVEL_SYSTEM.BASKETBALL_INTENSITY,
    aliases: const [],
  ),
  ActivityType(
    id: 'badminton',
    name: '羽球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 8,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 10,
    levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
    aliases: const [],
  ),
  ActivityType(
    id: 'tennis',
    name: '網球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 8,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 10,
    levelSystem: LEVEL_SYSTEM.TENNIS_NTRP,
    aliases: const [],
  ),
  ActivityType(
    id: 'table_tennis',
    name: '桌球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 2,
    defaultMaxParticipants: 8,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 10,
    levelSystem: LEVEL_SYSTEM.TABLE_TENNIS_SKILL,
    aliases: const ['乒乓球', 'Ping Pong'],
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
    sortOrder: 20,
    levelSystem: LEVEL_SYSTEM.NONE,
    aliases: const [],
  ),
];

final _testUser = AppUser(
  id: 'test-user-1',
  email: 'test@nycu.edu.tw',
  school: SCHOOL.NYCU,
  displayName: '測試者',
  avatarUrl: 'https://avatar/1',
  bio: '測試自我介紹',
  degreeLevel: DEGREE_LEVEL.UNDERGRAD,
  createdAt: DateTime(2026),
  defaultCampus: '光復',
);

class _MockSubmissionGateway
    implements MatchRequestSubmissionGateway, MatchRequestSubmissionSession {
  final createdRequests = <Map<String, dynamic>>[];

  @override
  MatchRequestSubmissionSession capture(WidgetRef ref) => this;

  @override
  Future<MatchRequest> create({
    required String activityTypeId,
    required String campus,
    required DateTime earliestStart,
    required DateTime latestStart,
    required int minParticipants,
    required int maxParticipants,
    required bool allowDowngrade,
    required String? sportLevel,
    int? sportLevelRating,
    required String? studyTarget,
  }) async {
    createdRequests.add({
      'activityTypeId': activityTypeId,
      'campus': campus,
      'sportLevel': sportLevel,
      'sportLevelRating': sportLevelRating,
      'studyTarget': studyTarget,
    });
    return MatchRequest(
      id: 'mock-req-id',
      ownerId: _testUser.id,
      activityTypeId: activityTypeId,
      earliestStart: earliestStart,
      latestStart: latestStart,
      flexibleMinutes: 0,
      minParticipants: minParticipants,
      maxParticipants: maxParticipants,
      allowDowngrade: allowDowngrade,
      status: REQUEST_STATUS.DRAFT,
      createdAt: DateTime(2026),
      school: SCHOOL.NYCU,
      campus: campus,
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
      activityTypeId: 'tennis',
      earliestStart: DateTime.now(),
      latestStart: DateTime.now().add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      maxParticipants: 4,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: DateTime(2026),
      school: SCHOOL.NYCU,
      campus: '光復',
    );
  }
}

Widget _buildTestApp({required _MockSubmissionGateway gateway}) {
  return ProviderScope(
    overrides: [
      myActiveRequestProvider.overrideWith((ref) async => null),
      myActiveActivityProvider.overrideWith((ref) async => null),
      activityTypesProvider.overrideWith((ref) async => _testTypes),
      myAppUserProvider.overrideWith((ref) async => _testUser),
      campusOptionsProvider.overrideWith((ref, school) async => ['光復']),
      myReliabilityProvider.overrideWith(
        (ref) async => MyReliability(
          tier: ReliabilityTier.normal,
          isNewUser: false,
        ),
      ),
      campusPulseProvider.overrideWith(
        (ref, key) => Stream.value(const <CampusPulseEntry>[]),
      ),
      myActiveAlertSubscriptionsProvider.overrideWith(
        (ref) async => const <ActivityAlertSubscription>[],
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: CreateRequestScreen(
        submissionGateway: gateway,
        now: () => DateTime(2026, 8, 15, 10, 0),
      ),
    ),
  );
}

Future<void> _scrollBackToTop(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byWidgetPredicate(
      (widget) => widget is AppSection && widget.title == '活動',
    ),
    -300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Basketball renders intensity options (輕鬆, 一般, 高強度, 競技)', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('籃球'));
    await tester.pumpAndSettle();
    await _scrollBackToTop(tester);

    expect(find.text('籃球強度'), findsOneWidget);
    expect(find.text('不限'), findsWidgets);
    expect(find.text('輕鬆'), findsOneWidget);
    expect(find.text('一般'), findsOneWidget);
    expect(find.text('高強度'), findsOneWidget);
    expect(find.text('競技'), findsOneWidget);
  });

  testWidgets('Tennis renders NTRP options and helper text', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('網球'));
    await tester.pumpAndSettle();
    await _scrollBackToTop(tester);

    expect(find.text('網球 NTRP'), findsOneWidget);
    expect(find.text('不知道 NTRP 沒關係，可選不限'), findsOneWidget);
    expect(find.text('不限 / 不知道'), findsOneWidget);
    expect(find.text('≤2.0'), findsOneWidget);
    expect(find.text('2.5'), findsOneWidget);
    expect(find.text('3.0'), findsOneWidget);
    expect(find.text('3.5'), findsOneWidget);
    expect(find.text('4.0'), findsOneWidget);
    expect(find.text('4.5'), findsOneWidget);
    expect(find.text('5.0+'), findsOneWidget);
  });

  testWidgets('Table tennis renders skill options and optional rating input', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('桌球'));
    await tester.pumpAndSettle();
    await _scrollBackToTop(tester);

    expect(find.text('桌球實力'), findsOneWidget);
    expect(find.text('不限 / 不確定'), findsOneWidget);
    expect(find.text('休閒新手'), findsOneWidget);
    expect(find.text('有基本功'), findsOneWidget);
    expect(find.text('固定打球'), findsOneWidget);
    expect(find.text('校隊 / 積分賽'), findsOneWidget);
    expect(find.widgetWithText(TextField, '積分（選填）'), findsOneWidget);
  });

  testWidgets('Switching to non-sport type hides sport level selector', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildTestApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('網球'));
    await tester.pumpAndSettle();
    await _scrollBackToTop(tester);
    expect(find.text('網球 NTRP'), findsOneWidget);

    await tester.tap(find.text('讀書'));
    await tester.pumpAndSettle();
    await _scrollBackToTop(tester);
    expect(find.text('網球 NTRP'), findsNothing);
    expect(find.text('想找同樣在準備什麼的人？（選填）'), findsOneWidget);
  });
}
