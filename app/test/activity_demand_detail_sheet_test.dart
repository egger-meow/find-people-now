import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/match/widgets/activity_demand_detail_sheet.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final testDemand = CampusDemandCard(
    activityTypeId: 'test-study-id',
    activityTypeName: '讀書',
    campus: '國立陽明交通大學 光復校區 基礎科學大樓 地下二樓桌球教室室內多功能室',
    earliestStart: DateTime(2026, 9, 16, 23, 0),
    latestStart: DateTime(2026, 9, 17, 1, 0),
    sportLevel: null,
    sportLevelRating: null,
    studyTarget: '高等工程數學與偏微分方程期中考衝刺題庫研討',
    minParticipants: 2,
    maxParticipants: 6,
    personCount: 3,
    requestCount: 2,
  );

  Widget buildSheetHost({
    required CampusDemandCard demand,
    bool canParticipate = true,
    String? disabledReason,
    TextScaler? textScaler,
    VoidCallback? onParticipate,
    VoidCallback? onCustomize,
  }) {
    return MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            textScaler: textScaler ?? TextScaler.noScaling,
            size: const Size(390, 844),
          ),
          child: ActivityDemandDetailSheet(
            demand: demand,
            canParticipate: canParticipate,
            disabledReason: disabledReason,
            relativeNow: DateTime(2026, 9, 16, 20, 0),
            onParticipate: onParticipate ?? () {},
            onCustomize: onCustomize ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('renders normally under standard 1.0x text scaling without overflow', (tester) async {
    await tester.pumpWidget(buildSheetHost(demand: testDemand));
    await tester.pumpAndSettle();

    expect(find.text('讀書'), findsOneWidget);
    expect(find.text('匿名活動需求確認'), findsOneWidget);
    expect(find.text('可開始時段'), findsOneWidget);
    expect(find.text('活動校區'), findsOneWidget);
    expect(find.text('程度 / 條件'), findsOneWidget);
    expect(find.text('人數規模'), findsOneWidget);
    expect(find.text('2 至 6 人'), findsOneWidget);
    expect(find.text('我也想去'), findsOneWidget);
    expect(find.textContaining('以此條件微調'), findsOneWidget);
  });

  testWidgets('renders long content without RenderFlex overflow under 200% text scaling', (tester) async {
    await tester.pumpWidget(buildSheetHost(
      demand: testDemand,
      textScaler: const TextScaler.linear(2.0),
    ));
    await tester.pumpAndSettle();

    // 驗證長校區名稱與長讀書科目在 200% 大字級下皆成功渲染且未引發 RenderFlex 溢出
    expect(find.text('國立陽明交通大學 光復校區 基礎科學大樓 地下二樓桌球教室室內多功能室'), findsOneWidget);
    expect(find.text('科目：高等工程數學與偏微分方程期中考衝刺題庫研討'), findsOneWidget);
    expect(find.text('今天晚上 23:00–明天 01:00 可開始'), findsOneWidget);
    expect(find.text('我也想去'), findsOneWidget);
  });

  testWidgets('triggers onParticipate callback when clicking participate button', (tester) async {
    bool participated = false;

    await tester.pumpWidget(buildSheetHost(
      demand: testDemand,
      onParticipate: () => participated = true,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我也想去'));
    await tester.pumpAndSettle();
    expect(participated, isTrue);
  });

  testWidgets('triggers onCustomize callback when clicking customize button', (tester) async {
    bool customized = false;

    await tester.pumpWidget(buildSheetHost(
      demand: testDemand,
      onCustomize: () => customized = true,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('以此條件微調'));
    await tester.pumpAndSettle();
    expect(customized, isTrue);
  });

  testWidgets('displays disabled reason and disables participation button when canParticipate is false', (tester) async {
    await tester.pumpWidget(buildSheetHost(
      demand: testDemand,
      canParticipate: false,
      disabledReason: '你已在配對等待室中，無法同時加入其他活動',
      textScaler: const TextScaler.linear(2.0),
    ));
    await tester.pumpAndSettle();

    expect(find.text('你已在配對等待室中，無法同時加入其他活動'), findsOneWidget);

    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '我也想去'));
    expect(button.onPressed, isNull);
  });
}
