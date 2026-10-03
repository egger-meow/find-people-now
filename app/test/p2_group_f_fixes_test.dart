import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/my_activities_providers.dart';
import 'package:find_people_now/activities/my_activities_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/notification.dart' as generated;
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/notifications/notification_providers.dart';
import 'package:find_people_now/notifications/notifications_screen.dart';
import 'package:find_people_now/profile/feedback_screen.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final now = DateTime.utc(2026, 9, 28, 12, 0);

  testWidgets('F30: 通知項目顯示發生時間標籤與活動情境標籤', (tester) async {
    final notification = generated.Notification(
      id: 'notif-f30',
      userId: 'u1',
      eventType: NOTIFICATION_EVENT_TYPE.MATCH_SUCCESS,
      payload: {
        'activity_id': 'act-123',
        'activity_type_name': '羽球',
        'campus': '光復',
      },
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'u1'),
          notificationsStreamProvider.overrideWith(
            (ref) => Stream.value([notification]),
          ),
          myActiveActivityProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const NotificationsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('配對成功！'), findsOneWidget);
    expect(find.text('5 分鐘前'), findsOneWidget);
    expect(find.text('羽球 · 光復'), findsOneWidget);
  });

  testWidgets('F31: 活動清單顯示關鍵待辦標籤（待提出/投票地點）', (tester) async {
    final activity = Activity(
      id: 'act-f31',
      activityTypeId: 'badminton',
      startTime: DateTime.now().add(const Duration(hours: 2)),
      estimatedEndTime: DateTime.now().add(const Duration(hours: 4)),
      status: ACTIVITY_STATUS.MATCHED,
      contactVisibleUntil: DateTime.now().add(const Duration(days: 1)),
      createdAt: now,
      school: SCHOOL.NYCU,
      campus: '光復',
    );

    final item = MyActivityListItem.activity(activity);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activityTypesProvider.overrideWith(
            (ref) async => [
              ActivityType(
                id: 'badminton',
                name: '羽球',
                status: ACTIVITY_TYPE_STATUS.APPROVED,
                createdAt: now,
                skillLevelEnabled: false,
                sortOrder: 1,
                levelSystem: LEVEL_SYSTEM.NONE,
                aliases: const [],
              ),
            ],
          ),
          myActivityListProvider.overrideWith(
            (ref) async => [item],
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const MyActivitiesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('羽球'), findsWidgets);
    expect(find.text('待辦：待提出/投票地點'), findsOneWidget);
  });

  testWidgets('F32: 反饋常見問題更新，無「未來評估」並指向正確表單入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'u1'),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const FeedbackScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('常見問題'), findsOneWidget);
    expect(find.text('活動可以選科目或程度嗎？'), findsOneWidget);

    // Expand FAQ tile
    await tester.tap(find.text('活動可以選科目或程度嗎？'));
    await tester.pumpAndSettle();

    expect(find.textContaining('目前運動類活動（羽球、網球、桌球、籃球、排球等）已全面支援程度分級'), findsOneWidget);
    expect(find.textContaining('未來評估'), findsNothing);
  });
}
