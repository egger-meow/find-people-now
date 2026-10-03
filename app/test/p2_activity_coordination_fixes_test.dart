import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final now = DateTime.utc(2026, 9, 28, 12, 0);

  final testActivity = Activity(
    id: 'act-test-f26-f27',
    activityTypeId: 'board-game',
    startTime: DateTime(2026, 9, 28, 14, 0),
    estimatedEndTime: DateTime(2026, 9, 28, 16, 0),
    status: ACTIVITY_STATUS.MATCHED,
    contactVisibleUntil: DateTime(2026, 9, 29, 14, 0),
    createdAt: now,
    school: SCHOOL.NYCU,
    campus: '光復',
  );

  testWidgets('F26: ActivityDetailBodyLayout 縮減頂部邊距與 Delegate 高度，維持首屏可達性', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailBodyLayout(
            summary: const Text('狀態摘要'),
            navigation: const Text('分頁導覽'),
            content: const Text('內容'),
            stickyAction: const Text('動作按鈕'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('狀態摘要'), findsOneWidget);
    expect(find.text('分頁導覽'), findsOneWidget);
    expect(find.text('動作按鈕'), findsOneWidget);
  });

  testWidgets('F27: Section 0 與 Section 1 Sticky Action 語意與分頁情境完全一致', (tester) async {
    // 1. On Section 0 (Location tab), MATCHED without options -> 前往提出候選地點
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.MATCHED,
            hasLocationOptions: false,
            sectionIndex: 0,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('前往提出候選地點'), findsOneWidget);

    // 2. On Section 1 (Members tab), MATCHED without options -> 返回地點頁提出候選
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.MATCHED,
            hasLocationOptions: false,
            sectionIndex: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返回地點頁提出候選'), findsOneWidget);

    // 3. On Section 1 (Members tab), MATCHED with options -> 返回地點頁參與投票
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.MATCHED,
            hasLocationOptions: true,
            sectionIndex: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返回地點頁參與投票'), findsOneWidget);
  });
}
