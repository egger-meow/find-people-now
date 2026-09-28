import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_providers.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_location_option.dart';
import 'package:find_people_now/generated/activity_location_vote.dart';
import 'package:find_people_now/generated/activity_meeting_point_update.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart'
    show activityTypesProvider;
import 'package:find_people_now/rpc/auth_profile_rpc.dart'
    show ReliabilityTier;
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final now = DateTime(2026, 9, 28, 14, 0);

  final testActivity = Activity(
    id: 'activity-coord-1',
    activityTypeId: 'board-game',
    startTime: DateTime(2026, 9, 28, 15, 0),
    estimatedEndTime: DateTime(2026, 9, 28, 17, 0),
    status: ACTIVITY_STATUS.MATCHED,
    contactVisibleUntil: DateTime(2026, 9, 29, 15, 0),
    createdAt: now,
    school: SCHOOL.NYCU,
    campus: '光復',
    activityLocationId: 'opt-1',
  );

  final opt1 = ActivityLocationOption(
    id: 'opt-1',
    activityId: 'activity-coord-1',
    customName: '學生活動中心桌遊室',
    proposedBy: 'user-a',
    createdAt: now,
  );

  final opt2 = ActivityLocationOption(
    id: 'opt-2',
    activityId: 'activity-coord-1',
    customName: '一餐二樓咖啡區',
    proposedBy: 'user-b',
    createdAt: now.add(const Duration(minutes: 5)),
  );

  final vote1 = ActivityLocationVote(
    activityId: 'activity-coord-1',
    userId: 'user-a',
    votedAt: now,
    optionId: 'opt-1',
  );

  final vote2 = ActivityLocationVote(
    activityId: 'activity-coord-1',
    userId: 'user-b',
    votedAt: now,
    optionId: 'opt-2',
  );

  final update1 = ActivityMeetingPointUpdate(
    id: 'mp-1',
    activityId: 'activity-coord-1',
    updatedBy: 'user-a',
    description: '大門警衛室旁長椅',
    createdAt: DateTime(2026, 9, 28, 14, 10),
  );

  final update2 = ActivityMeetingPointUpdate(
    id: 'mp-2',
    activityId: 'activity-coord-1',
    updatedBy: 'user-b',
    description: '二樓樓梯口玻璃門前',
    createdAt: DateTime(2026, 9, 28, 14, 30),
  );

  testWidgets(
    'ActivityDetailStatusSummary displays 3-tier space separation clearly',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'user-a'),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: ActivityDetailStatusSummary(
                activity: testActivity,
                locationOptions: [opt1],
                locationVotes: [vote1],
                fixtureLocations: const [],
                meetingPointUpdates: [update1],
                myMeetingHint: '穿黑色帽T、背藍色後背包',
                currentTime: DateTime(2026, 9, 28, 12, 0),
              ),
            ),
          ),
        ),
      );

      // Tier 1: 活動地點
      expect(find.textContaining('活動地點（地點投票）：學生活動中心桌遊室目前領先（1 票，仍可變更）'), findsOneWidget);
      // Tier 2: 集合地點
      expect(find.textContaining('集合地點：大門警衛室旁長椅'), findsOneWidget);
      // Tier 3: 見面提示
      expect(find.textContaining('見面提示：穿黑色帽T、背藍色後背包'), findsOneWidget);
    },
  );

  testWidgets(
    'ActivityDetailStatusSummary shows tie notification and updated meetup badge when multiple updates exist',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'user-a'),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: ActivityDetailStatusSummary(
                activity: testActivity,
                locationOptions: [opt1, opt2],
                locationVotes: [vote1, vote2], // 1 vote each -> tie!
                fixtureLocations: const [],
                meetingPointUpdates: [update2, update1], // 2 updates -> changed!
                myMeetingHint: null, // empty hint
                currentTime: DateTime(2026, 9, 28, 12, 0),
              ),
            ),
          ),
        ),
      );

      // Tie suffix in location summary
      expect(find.textContaining('（平票中，等待其他成員投票決定）'), findsOneWidget);
      // Updated meetup point with timestamp
      expect(find.textContaining('集合地點：二樓樓梯口玻璃門前（已於 14:30 更新）'), findsOneWidget);
      // Unfilled hint guidance
      expect(find.textContaining('見面提示：尚未填寫（可到「成員與聯絡」說明衣著特徵以利相認）'), findsOneWidget);
    },
  );

  testWidgets(
    'ActivityDetailStatusSummary warns when starting in less than 1 hour with unsettled location or meetup',
    (tester) async {
      final startingSoonActivity = Activity(
        id: 'starting-soon',
        activityTypeId: 'study',
        startTime: DateTime(2026, 9, 28, 15, 0),
        estimatedEndTime: DateTime(2026, 9, 28, 17, 0),
        status: ACTIVITY_STATUS.MATCHED,
        contactVisibleUntil: DateTime(2026, 9, 29, 15, 0),
        createdAt: now,
        school: SCHOOL.NYCU,
        campus: '光復',
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: ActivityDetailStatusSummary(
                activity: startingSoonActivity,
                locationOptions: const [], // no location proposed yet!
                locationVotes: const [],
                fixtureLocations: const [],
                meetingPointUpdates: const [], // no meetup point yet!
                currentTime: DateTime(2026, 9, 28, 14, 30), // 30 minutes before start
              ),
            ),
          ),
        ),
      );

      expect(
        find.textContaining('⚠️ 活動即將開始，但地點與集合方式尚未確定！請儘速確認。'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'ActivityDetailStickyAction displays focused single action for arrived/unarrived user',
    (tester) async {
      var arrivedPressed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ActivityDetailStickyAction(
              status: ACTIVITY_STATUS.ONGOING,
              hasLocationOptions: true,
              customLabel: '我到了',
              customIcon: Icons.near_me_rounded,
              onPressed: () {
                arrivedPressed = true;
              },
            ),
          ),
        ),
      );

      expect(find.text('我到了'), findsOneWidget);
      expect(find.byIcon(Icons.near_me_rounded), findsOneWidget);

      await tester.tap(find.text('我到了'));
      await tester.pump();
      expect(arrivedPressed, isTrue);
    },
  );

  testWidgets(
    'ActivityDetailStatusSummary shows custom deadline when canMarkArrived is true',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: ActivityDetailStatusSummary(
                activity: testActivity,
                locationOptions: [opt1],
                locationVotes: [vote1],
                fixtureLocations: const [],
                meetingPointUpdates: [update1],
                canMarkArrived: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('下一步：抵達集合地點並點擊「我到了」'), findsOneWidget);
    },
  );

  testWidgets(
    'MembersTab displays cancellation notice banner when a member has cancelled',
    (tester) async {
      final roster = [
        MemberRosterEntry(
          userId: 'user-a',
          sourceRequestId: 'req-1',
          status: ACTIVITY_MEMBER_STATUS.JOINED,
          displayName: '小明',
          avatarUrl: '',
          contacts: null,
          school: SCHOOL.NYCU,
          department: '資工系',
          degreeLevel: DEGREE_LEVEL.UNDERGRAD,
          bio: '',
          reliabilityTier: ReliabilityTier.normal,
          meetingHint: null,
          arrivedAt: null,
          vibeTags: const [],
          studyTarget: null,
        ),
        MemberRosterEntry(
          userId: 'user-b',
          sourceRequestId: 'req-2',
          status: ACTIVITY_MEMBER_STATUS.CANCELLED,
          displayName: '小華',
          avatarUrl: '',
          contacts: null,
          school: SCHOOL.NYCU,
          department: '電機系',
          degreeLevel: DEGREE_LEVEL.UNDERGRAD,
          bio: '',
          reliabilityTier: ReliabilityTier.normal,
          meetingHint: null,
          arrivedAt: null,
          vibeTags: const [],
          studyTarget: null,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'user-a'),
            activityMemberRosterProvider('activity-coord-1')
                .overrideWith((ref) async => roster),
            activityArrivalStreamProvider('activity-coord-1')
                .overrideWith((ref) => const AsyncValue.data(<String, DateTime?>{})),
            activityVibeTagsStreamProvider('activity-coord-1')
                .overrideWith((ref) => const AsyncValue.data(<String, List<String>>{})),
            activityMeetingHintStreamProvider('activity-coord-1')
                .overrideWith((ref) => const AsyncValue.data(<String, String?>{})),
            activityTypesProvider.overrideWith((ref) async => []),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(
              body: MembersTab(
                activityId: 'activity-coord-1',
                activityStatus: ACTIVITY_STATUS.MATCHED,
                activityTypeId: 'board-game',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('已有 1 位夥伴退出本次活動'), findsOneWidget);
      expect(find.textContaining('目前活動成員剩餘 1 人'), findsOneWidget);
    },
  );
}
