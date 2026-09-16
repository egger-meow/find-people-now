import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/widgets/pinned_active_status_card.dart';

void main() {
  testWidgets('renders SizedBox.shrink when no active request or activity',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PinnedActiveStatusCard(request: null, activity: null),
        ),
      ),
    );

    expect(find.byType(PinnedActiveStatusCard), findsOneWidget);
    expect(find.text('你正在配對中'), findsNothing);
    expect(find.text('你目前有進行中的活動'), findsNothing);
  });

  testWidgets('renders active match request banner with waiting room button',
      (tester) async {
    var openedWaitingRoom = false;
    final mockRequest = MatchRequest(
      id: 'req-1',
      ownerId: 'user-1',
      activityTypeId: 'act-1',
      earliestStart: DateTime.now(),
      latestStart: DateTime.now().add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      maxParticipants: 4,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: DateTime.now(),
      school: SCHOOL.NYCU,
      campus: '光復校區',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinnedActiveStatusCard(
            request: mockRequest,
            activity: null,
            onOpenWaitingRoom: () => openedWaitingRoom = true,
          ),
        ),
      ),
    );

    expect(find.text('你正在配對中'), findsOneWidget);
    expect(find.text('前往等待室'), findsOneWidget);
    expect(find.textContaining('瀏覽校園動態'), findsOneWidget);

    await tester.tap(find.text('前往等待室'));
    expect(openedWaitingRoom, isTrue);
  });

  testWidgets('renders active activity banner with activity button',
      (tester) async {
    var openedActivity = false;
    final mockActivity = Activity(
      id: 'act-1',
      activityTypeId: 'type-1',
      startTime: DateTime.now().add(const Duration(hours: 1)),
      estimatedEndTime: DateTime.now().add(const Duration(hours: 2)),
      status: ACTIVITY_STATUS.MATCHED,
      contactVisibleUntil: DateTime.now().add(const Duration(hours: 24)),
      createdAt: DateTime.now(),
      school: SCHOOL.NYCU,
      campus: '光復校區',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinnedActiveStatusCard(
            request: null,
            activity: mockActivity,
            onOpenActivity: () => openedActivity = true,
          ),
        ),
      ),
    );

    expect(find.text('你目前有進行中的活動'), findsOneWidget);
    expect(find.text('前往活動房間'), findsOneWidget);

    await tester.tap(find.text('前往活動房間'));
    expect(openedActivity, isTrue);
  });
}
