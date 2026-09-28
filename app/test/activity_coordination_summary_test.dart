import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_meeting_point_update.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_sticky_action_area.dart';

void main() {
  final start = DateTime(2026, 9, 28, 18);
  final activity = Activity(
    id: 'coordination-summary',
    activityTypeId: 'coffee',
    startTime: start,
    estimatedEndTime: start.add(const Duration(hours: 1)),
    status: ACTIVITY_STATUS.MATCHED,
    contactVisibleUntil: start.add(const Duration(days: 1)),
    createdAt: start.subtract(const Duration(hours: 2)),
    school: SCHOOL.NYCU,
    campus: '光復',
  );

  testWidgets('開始前尚無地點與集合方式時清楚提示，並維持單一下一步', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ActivityDetailStatusSummary(
              activity: activity,
              locationOptions: const [],
              locationVotes: const [],
              fixtureLocations: const [],
              meetingPointUpdates: const [],
              myMeetingHint: '',
              currentTime: start.subtract(const Duration(minutes: 20)),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('地點與集合方式尚未確定'), findsOneWidget);
    expect(find.textContaining('活動地點：等待提出候選地點'), findsOneWidget);
    expect(find.textContaining('集合地點：尚未設定'), findsNothing);
    expect(find.text('下一步：提出候選地點'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首屏顯示最新集合點與更新時間，並區分我的見面提示', (tester) async {
    final updates = [
      ActivityMeetingPointUpdate(
        id: 'new',
        activityId: activity.id,
        updatedBy: 'member-a',
        description: '圖書館正門',
        createdAt: start.subtract(const Duration(minutes: 30)),
      ),
      ActivityMeetingPointUpdate(
        id: 'old',
        activityId: activity.id,
        updatedBy: 'member-a',
        description: '咖啡廳門口',
        createdAt: start.subtract(const Duration(hours: 1)),
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ActivityDetailStatusSummary(
              activity: activity,
              locationOptions: const [],
              locationVotes: const [],
              fixtureLocations: const [],
              meetingPointUpdates: updates,
              myMeetingHint: '藍色背包',
              currentTime: start.subtract(const Duration(hours: 2)),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('集合地點：圖書館正門（已於'), findsOneWidget);
    expect(find.textContaining('我的見面提示：藍色背包'), findsOneWidget);
    expect(find.textContaining('咖啡廳門口'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短橫向畫面與 200% 字級仍可查看資訊與主要操作', (tester) async {
    const size = Size(844, 390);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: MediaQuery(
            data: const MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: SafeArea(
                child: ActivityDetailBodyLayout(
                  summary: ActivityDetailStatusSummary(
                    activity: activity,
                    locationOptions: const [],
                    locationVotes: const [],
                    fixtureLocations: const [],
                    meetingPointUpdates: const [],
                    myMeetingHint: '',
                    currentTime: start.subtract(const Duration(hours: 2)),
                  ),
                  navigation: const SizedBox(height: 44, child: Text('地點與集合')),
                  content: const SingleChildScrollView(child: Text('活動內容')),
                  stickyAction: ActivityDetailStickyAction(
                    status: activity.status,
                    hasLocationOptions: false,
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下一步：提出候選地點'), findsOneWidget);
    expect(find.byType(AppStickyActionArea).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
