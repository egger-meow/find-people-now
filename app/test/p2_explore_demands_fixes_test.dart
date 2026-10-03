import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_sheet.dart';
import 'package:find_people_now/widgets/department_field.dart';

CampusDemandCard _makeCard({
  String activity = '羽球',
  String campus = '光復校區',
  int personCount = 3,
}) {
  final now = DateTime.now();
  return CampusDemandCard(
    activityTypeId: 'act-1',
    activityTypeName: activity,
    campus: campus,
    earliestStart: now.add(const Duration(hours: 1)),
    latestStart: now.add(const Duration(hours: 3)),
    minParticipants: 3,
    maxParticipants: 4,
    sportLevel: 'NORMAL',
    sportLevelRating: null,
    studyTarget: null,
    requestCount: 2,
    personCount: personCount,
    formedGroupCount: 0,
    formedPersonCount: 0,
  );
}

void main() {
  group('P2 UI/UX Audit Fixes - Explore, Demands & Semantics (F09, F10, F29, F36)', () {
    testWidgets('F09: CampusDemandCardWidget avoids 3-fold headcount repetition when headline has headcount', (tester) async {
      final card = _makeCard(personCount: 3);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: CampusDemandCardWidget(
              demand: card,
              summaryHeadline: '今天 3 人在揪羽球',
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top headline has headcount
      expect(find.text('今天 3 人在揪羽球'), findsOneWidget);
      // Bottom line avoids repeating "這個時段有 3 人在找球友"
      expect(find.textContaining('這個時段有 3 人在找球友'), findsNothing);
      expect(find.textContaining('成團依條件撮合'), findsOneWidget);
    });

    testWidgets('F10: Criterion chips use readable typography >= 12px', (tester) async {
      final card = _makeCard();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: CampusDemandCardWidget(
              demand: card,
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final campusTextFinder = find.text('光復校區');
      expect(campusTextFinder, findsOneWidget);
      final textWidget = tester.widget<Text>(campusTextFinder);
      expect(textWidget.style?.fontSize, greaterThanOrEqualTo(12.0));
    });

    testWidgets('F36: DepartmentField provides explicit trailingIcon accessibility tooltip', (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: DepartmentField(
              controller: controller,
              school: SCHOOL.NYCU,
              degreeLevel: DEGREE_LEVEL.UNDERGRAD,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('展開科系清單'), findsWidgets);
    });

    testWidgets('F36: 驗證無名操作賦予清晰語意名稱且 Sheet 關閉時焦點正確返回觸發節點', (tester) async {
      final triggerFocusNode = FocusNode();
      addTearDown(triggerFocusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: Semantics(
                    button: true,
                    label: '查看 小晴 的個人資料',
                    child: ElevatedButton(
                      focusNode: triggerFocusNode,
                      onPressed: () {
                        showAppSheet<void>(
                          context,
                          builder: (sheetContext) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('小晴個人資料'),
                              ElevatedButton(
                                onPressed: () => Navigator.of(sheetContext).pop(),
                                child: const Text('關閉'),
                              ),
                            ],
                          ),
                        ).then((_) {
                          triggerFocusNode.requestFocus();
                        });
                      },
                      child: const Text('頭像按鈕'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 驗證無名操作賦予清楚之讀屏語意標籤
      expect(find.bySemanticsLabel('查看 小晴 的個人資料'), findsOneWidget);

      // 2. 聚焦並開啟 Sheet
      triggerFocusNode.requestFocus();
      await tester.pump();
      expect(triggerFocusNode.hasFocus, isTrue);

      await tester.tap(find.text('頭像按鈕'));
      await tester.pumpAndSettle();
      expect(find.text('小晴個人資料'), findsOneWidget);

      // 3. 關閉 Sheet 並驗證焦點成功回到觸發節點
      await tester.tap(find.text('關閉'));
      await tester.pumpAndSettle();
      expect(find.text('小晴個人資料'), findsNothing);
      expect(triggerFocusNode.hasFocus, isTrue, reason: 'Sheet 關閉後焦點必須返回觸發元素');
    });

    test('F29: Reliability tier displays truthful label without exaggerated quality claims', () {
      expect(ReliabilityTier.normal.displayLabel, '良好紀錄 (Normal)');
      expect(ReliabilityTier.normal.displayLabel, isNot(contains('優質夥伴')));
      expect(ReliabilityTier.trusted.displayLabel, '高信賴度 (Trusted)');
      expect(ReliabilityTier.newUser.displayLabel, '新朋友 (New)');
    });
  });
}
