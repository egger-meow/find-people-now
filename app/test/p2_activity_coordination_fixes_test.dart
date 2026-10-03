import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  testWidgets('F26: ActivityDetailBodyLayout 縮減頂部邊距與 Delegate 高度，維持首屏可達性', (tester) async {
    // 1. 直向 390x844 視窗：驗證首屏內容、緊湊導覽列與固定動作列同時可見
    tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailBodyLayout(
            summary: const SizedBox(height: 120, child: Text('狀態摘要')),
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
    expect(find.text('內容'), findsOneWidget);
    expect(find.text('動作按鈕'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 2. 橫向短視窗 844x390：驗證橫向空間下導覽列、內容與固定操作依然可達，無任何溢出
    tester.view.physicalSize = const Size(844 * 2.0, 390 * 2.0);
    await tester.pumpAndSettle();

    expect(find.text('動作按鈕'), findsOneWidget);
    expect(find.text('分頁導覽'), findsOneWidget);
    final stickyActionDy = tester.getTopLeft(find.text('動作按鈕')).dy;
    expect(stickyActionDy, lessThan(390.0), reason: '橫向短螢幕下底部固定操作列必須在 390 像素視窗內可達');
    expect(tester.takeException(), isNull);
  });

  testWidgets('F27: Section 0 與 Section 1 Sticky Action 語意與分頁情境完全一致', (tester) async {
    // 1. On Section 0 (Location tab), MATCHED without options -> 提出地點
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
    expect(find.text('提出地點'), findsOneWidget);

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

    // 4. On Section 0 (Location tab), MATCHED with options -> 查看成員與聯絡
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.MATCHED,
            hasLocationOptions: true,
            sectionIndex: 0,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看成員與聯絡'), findsOneWidget);
  });
}
