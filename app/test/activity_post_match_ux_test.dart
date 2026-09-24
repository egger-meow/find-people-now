import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_providers.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_location_option.dart';
import 'package:find_people_now/generated/activity_location_vote.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/completion_report.dart';
import 'package:find_people_now/generated/location.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart' show ReliabilityTier;
import 'package:find_people_now/theme/app_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final now = DateTime.utc(2026, 9, 23, 14, 0);

  final testActivity = Activity(
    id: 'act-test-1',
    activityTypeId: 'act-type-badminton',
    school: SCHOOL.NYCU,
    campus: '光復',
    startTime: now,
    estimatedEndTime: now.add(const Duration(hours: 2)),
    contactVisibleUntil: now.add(const Duration(hours: 24)),
    status: ACTIVITY_STATUS.ONGOING,
    createdAt: now,
  );

  final testType = ActivityType(
    id: 'act-type-badminton',
    name: '羽球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: now,
    skillLevelEnabled: false,
    sortOrder: 1,
    levelSystem: LEVEL_SYSTEM.NONE,
    aliases: const [],
  );

  final myMember = MemberRosterEntry(
    userId: 'user-me',
    sourceRequestId: 'req-1',
    status: ACTIVITY_MEMBER_STATUS.JOINED,
    displayName: '小明',
    avatarUrl: '',
    contacts: null,
    school: SCHOOL.NYCU,
    department: '資工系',
    degreeLevel: DEGREE_LEVEL.UNDERGRAD,
    bio: '',
    reliabilityTier: ReliabilityTier.trusted,
    meetingHint: '',
    arrivedAt: null,
    vibeTags: const [],
    studyTarget: '',
  );

  Widget createSubject({
    required Activity activity,
    required CompletionReport? ownReport,
    required List<MemberRosterEntry> roster,
    Map<String, DateTime?>? arrivalData,
  }) {
    return ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => 'user-me'),
        activityStreamProvider(activity.id).overrideWith(
          (ref) => Stream.value(activity),
        ),
        activityLocationOptionsStreamProvider(activity.id).overrideWith(
          (ref) => Stream.value(<ActivityLocationOption>[]),
        ),
        activityLocationVotesStreamProvider(activity.id).overrideWith(
          (ref) => Stream.value(<ActivityLocationVote>[]),
        ),
        approvedLocationsProvider((activity.school, activity.campus)).overrideWith(
          (ref) async => <Location>[],
        ),
        ownCompletionReportProvider(activity.id).overrideWith(
          (ref) async => ownReport,
        ),
        activityMemberRosterProvider(activity.id).overrideWith(
          (ref) async => roster,
        ),
        activityArrivalStreamProvider(activity.id).overrideWithValue(
          AsyncData(arrivalData ?? {}),
        ),
        activityVibeTagsStreamProvider(activity.id).overrideWith(
          (ref) => const AsyncData(<String, List<String>>{}),
        ),
        activityMeetingHintStreamProvider(activity.id).overrideWith(
          (ref) => const AsyncData(<String, String?>{}),
        ),
        activityMeetingPointUpdatesStreamProvider(activity.id).overrideWith(
          (ref) => Stream.value(const []),
        ),
        activityTypesProvider.overrideWith((ref) async => [testType]),
        supabaseClientProvider.overrideWithValue(
          SupabaseClient(
            'http://127.0.0.1:65535',
            'test-anon-key',
            authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: ActivityDetailScreen(activityId: activity.id),
      ),
    );
  }

  group('Activity Completion Report Banner UX', () {
    testWidgets('shows start report button when user has not reported', (tester) async {
      await tester.pumpWidget(
        createSubject(
          activity: testActivity,
          ownReport: null,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('活動完成回報'), findsOneWidget);
      expect(find.text('開始回報'), findsOneWidget);
    });

    testWidgets('shows persistent reported status and rematch button when already reported', (tester) async {
      final report = CompletionReport(
        id: 'rep-1',
        activityId: testActivity.id,
        reporterId: 'user-me',
        result: COMPLETION_RESULT.WENT_WELL,
        absentUserIds: const [],
        createdAt: now,
      );

      await tester.pumpWidget(
        createSubject(
          activity: testActivity,
          ownReport: report,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已完成活動回報'), findsOneWidget);
      expect(find.text('想再約其他成員'), findsOneWidget);
      expect(find.text('開始回報'), findsNothing);
    });

    testWidgets('shows start report button on COMPLETED activity when within reporting window', (tester) async {
      final completedActivityWithinWindow = testActivity.copyWith(
        status: ACTIVITY_STATUS.COMPLETED,
        contactVisibleUntil: DateTime.now().add(const Duration(hours: 12)),
      );

      await tester.pumpWidget(
        createSubject(
          activity: completedActivityWithinWindow,
          ownReport: null,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('活動完成回報'), findsOneWidget);
      expect(find.text('活動已順利結束！花 10 秒回報出席狀況以維護信譽'), findsOneWidget);
      expect(find.text('開始回報'), findsOneWidget);
    });

    testWidgets('shows start report button on COMPLETED activity when contactVisibleUntil is past but startTime + 24h is still valid', (tester) async {
      final activityWithValidStartTimeWindow = testActivity.copyWith(
        status: ACTIVITY_STATUS.COMPLETED,
        startTime: DateTime.now().subtract(const Duration(hours: 2)),
        contactVisibleUntil: DateTime.now().subtract(const Duration(hours: 1)),
      );

      await tester.pumpWidget(
        createSubject(
          activity: activityWithValidStartTimeWindow,
          ownReport: null,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('活動完成回報'), findsOneWidget);
      expect(find.text('開始回報'), findsOneWidget);
    });

    testWidgets('hides start report button on COMPLETED activity when reporting window expired', (tester) async {
      final expiredCompletedActivity = testActivity.copyWith(
        status: ACTIVITY_STATUS.COMPLETED,
        contactVisibleUntil: DateTime.now().subtract(const Duration(hours: 1)),
      );

      await tester.pumpWidget(
        createSubject(
          activity: expiredCompletedActivity,
          ownReport: null,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('活動完成回報'), findsNothing);
      expect(find.text('開始回報'), findsNothing);
    });
  });

  group('Activity Arrival Check-in UX', () {
    testWidgets('shows check-in button in top arrival section when not yet arrived', (tester) async {
      await tester.pumpWidget(
        createSubject(
          activity: testActivity,
          ownReport: null,
          roster: [myMember],
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Members tab
      await tester.tap(find.text('成員與聯絡'));
      await tester.pumpAndSettle();

      expect(find.text('報到狀態'), findsOneWidget);
      expect(find.text('已抵達 0 / 1'), findsOneWidget);
      expect(find.text('我到了'), findsWidgets);
    });

    testWidgets('shows persistent check-in confirmation at top when arrived', (tester) async {
      final arrivedMember = myMember.copyWithArrivedAt(now);

      await tester.pumpWidget(
        createSubject(
          activity: testActivity,
          ownReport: null,
          roster: [arrivedMember],
          arrivalData: {'user-me': now},
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Members tab
      await tester.tap(find.text('成員與聯絡'));
      await tester.pumpAndSettle();

      expect(find.text('報到狀態'), findsOneWidget);
      expect(find.text('已抵達 1 / 1'), findsOneWidget);
      expect(find.textContaining('你已於'), findsOneWidget);
    });
  });

  group('Member Safety Report Sheet UX', () {
    testWidgets('uses ChoiceChips instead of dropdown for report categories', (tester) async {
      final otherMember = MemberRosterEntry(
        userId: 'user-other',
        sourceRequestId: 'req-2',
        status: ACTIVITY_MEMBER_STATUS.JOINED,
        displayName: '小華',
        avatarUrl: '',
        contacts: null,
        school: SCHOOL.NYCU,
        department: '電機系',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: '',
        reliabilityTier: ReliabilityTier.normal,
        meetingHint: '',
        arrivedAt: null,
        vibeTags: const [],
        studyTarget: '',
      );

      await tester.pumpWidget(
        createSubject(
          activity: testActivity,
          ownReport: null,
          roster: [myMember, otherMember],
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Members tab
      await tester.tap(find.text('成員與聯絡'));
      await tester.pumpAndSettle();

      // Tap on other member to expand card
      await tester.scrollUntilVisible(find.text('小華'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('小華'));
      await tester.pumpAndSettle();

      // Scroll to and tap '檢舉' button
      await tester.scrollUntilVisible(find.text('檢舉'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('檢舉'));
      await tester.pumpAndSettle();

      // Verify report sheet opens
      expect(find.text('檢舉這位成員'), findsOneWidget);
      expect(find.text('檢舉類別'), findsOneWidget);

      // Verify ChoiceChips are used instead of DropdownButtonFormField
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      expect(find.text('騷擾廣告'), findsOneWidget);
      expect(find.text('不當言行'), findsOneWidget);
      expect(find.text('其他'), findsOneWidget);

      // Selecting a chip updates the category
      await tester.tap(find.text('不當言行'));
      await tester.pumpAndSettle();

      final chipWidget = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '不當言行'),
      );
      expect(chipWidget.selected, isTrue);
    });
  });
}

