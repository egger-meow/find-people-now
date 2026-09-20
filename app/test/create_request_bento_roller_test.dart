import 'package:flutter/cupertino.dart';
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
  id: 'user-bento-1',
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
    id: 'basketball',
    name: '籃球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 4,
    defaultMaxParticipants: 10,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 1,
    levelSystem: LEVEL_SYSTEM.BASKETBALL_INTENSITY,
    aliases: const [],
  ),
];

final _fixedNow = DateTime(2026, 9, 16, 14, 0);

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
    required String? sportLevel,
    int? sportLevelRating,
    required String? studyTarget,
  }) async {
    return MatchRequest(
      id: 'req-1',
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
    return MatchRequest(
      id: requestId,
      ownerId: _testUser.id,
      activityTypeId: 'basketball',
      earliestStart: _fixedNow,
      latestStart: _fixedNow.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 4,
      maxParticipants: 10,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: _fixedNow,
      school: SCHOOL.NYCU,
      campus: '光復',
    );
  }
}

Widget _buildApp({
  required _MockSubmissionGateway gateway,
  TargetPlatform platform = TargetPlatform.iOS,
}) {
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
      campusDemandsProvider.overrideWith(
        (ref, key) => Stream.value(const <CampusDemandCard>[]),
      ),
      myActiveAlertSubscriptionsProvider.overrideWith(
        (ref) async => const <ActivityAlertSubscription>[],
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light.copyWith(platform: platform),
      home: CreateRequestScreen(
        submissionGateway: gateway,
        now: () => _fixedNow,
      ),
    ),
  );
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Bento step badges and fluent time transition work smoothly', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway));
    await tester.pumpAndSettle();

    // Scroll to activity section
    await _scrollTo(tester, find.text('活動'));
    expect(find.text('1'), findsOneWidget);

    // Scroll to time section
    await _scrollTo(tester, find.text('時間'));
    expect(find.text('2'), findsOneWidget);

    // Initial state: Quick time buckets
    expect(find.text('現在'), findsOneWidget);
    expect(find.text('自訂時間'), findsOneWidget);
    expect(
      tester.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade)).crossFadeState,
      CrossFadeState.showFirst,
    );

    // Tap "自訂時間" to toggle fluent custom time tiles
    await tester.tap(find.text('自訂時間'));
    await tester.pumpAndSettle();

    expect(find.text('改選時段'), findsOneWidget);
    expect(
      tester.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade)).crossFadeState,
      CrossFadeState.showSecond,
    );

    // Toggle back
    await tester.tap(find.text('改選時段'));
    await tester.pumpAndSettle();
    expect(find.text('現在'), findsOneWidget);
    expect(
      tester.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade)).crossFadeState,
      CrossFadeState.showFirst,
    );
  });

  testWidgets('iOS platform renders CupertinoPicker headcount roller', (tester) async {
    final gateway = _MockSubmissionGateway();
    await tester.pumpWidget(_buildApp(gateway: gateway, platform: TargetPlatform.iOS));
    await tester.pumpAndSettle();

    // Select Basketball
    await _scrollTo(tester, find.text('籃球'));
    await tester.tap(find.text('籃球'));
    await tester.pumpAndSettle();

    // Scroll down to 人數 section
    await _scrollTo(tester, find.text('人數'));

    // Should render CupertinoPicker roller wheels for min and max
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
    expect(find.textContaining('至少 (4 人)'), findsOneWidget);
    expect(find.textContaining('至多 (10 人)'), findsOneWidget);
  });
}
