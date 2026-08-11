import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_button.dart';
import 'package:find_people_now/widgets/app_glass_surface.dart';
import 'package:find_people_now/widgets/app_section.dart';
import 'package:find_people_now/widgets/app_selection_summary.dart';
import 'package:find_people_now/widgets/app_status_summary.dart';
import 'package:find_people_now/widgets/app_sticky_action_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A missing title, primary action, or accessible target would make this fail.
  for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'calm-glass primitives remain usable at 200% text scale in $themeMode',
      (WidgetTester tester) async {
        await tester.pumpWidget(_buildHarness(themeMode));

        expect(find.text('目前狀態'), findsOneWidget);
        expect(find.text('開始建立配對'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const Key('primary-action'))).height,
          greaterThanOrEqualTo(44),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  // Reducing the semantic body style below 16px would make these component messages fail.
  testWidgets(
    'section descriptions and status messages use at least 16px body text',
    (WidgetTester tester) async {
      await tester.pumpWidget(_buildHarness(ThemeMode.light));

      expect(
        tester.widget<Text>(find.text('請確認配對條件後開始建立配對。')).style?.fontSize,
        greaterThanOrEqualTo(16),
      );
      expect(
        tester.widget<Text>(find.text('準備好後即可開始。')).style?.fontSize,
        greaterThanOrEqualTo(16),
      );
    },
  );

  // Removing the expanded state from the summary's semantic contract would make this fail.
  testWidgets(
    'selection summary exposes each condition in expanded and collapsed states',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(_buildSelectionSummaryHarness(expanded: true));

      expect(find.bySemanticsLabel('配對條件摘要，已展開'), findsOneWidget);
      expect(find.bySemanticsLabel('年級：大三'), findsOneWidget);
      expect(find.bySemanticsLabel('系所：資訊工程學系'), findsOneWidget);

      await tester.pumpWidget(_buildSelectionSummaryHarness(expanded: false));

      expect(find.bySemanticsLabel('配對條件摘要，已收合'), findsOneWidget);
      expect(find.bySemanticsLabel('年級：大三'), findsOneWidget);
      expect(find.bySemanticsLabel('系所：資訊工程學系'), findsOneWidget);
      semantics.dispose();
    },
  );

  // Omitting the keyboard or safe-area inset would change both the padding and action location.
  testWidgets('sticky action area clears keyboard and safe-area insets', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildStickyActionHarness());

    final padding = tester.widget<Padding>(
      find.descendant(
        of: find.byType(AppStickyActionArea),
        matching: find.byType(Padding),
      ),
    );
    expect((padding.padding as EdgeInsets).bottom, 332);
    expect(
      tester.getTopLeft(find.byKey(const Key('sticky-inset-action'))).dy,
      224,
    );
  });
}

Widget _buildHarness(ThemeMode themeMode, {bool selectionExpanded = true}) {
  return MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: themeMode,
    home: MediaQuery(
      data: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        padding: EdgeInsets.only(bottom: 24),
        viewPadding: EdgeInsets.only(bottom: 24),
        disableAnimations: true,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: AppGlassSurface(
                    child: AppSection(
                      title: '目前狀態',
                      description: '請確認配對條件後開始建立配對。',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppStatusSummary(
                            title: '尚未建立配對',
                            message: '準備好後即可開始。',
                          ),
                          const SizedBox(height: AppSpacing.md),
                          AppSelectionSummary(
                            expanded: selectionExpanded,
                            items: [
                              AppSelectionSummaryItem(label: '年級', value: '大三'),
                              AppSelectionSummaryItem(
                                label: '系所',
                                value: '資訊工程學系',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              AppStickyActionArea(
                child: AppButton(
                  key: Key('primary-action'),
                  label: '開始建立配對',
                  onPressed: _doNothing,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _buildStickyActionHarness() {
  return MaterialApp(
    theme: AppTheme.light,
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(400, 600),
        padding: EdgeInsets.only(bottom: 24),
        viewPadding: EdgeInsets.only(bottom: 24),
        viewInsets: EdgeInsets.only(bottom: 300),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AppStickyActionArea(
          child: SizedBox(
            key: Key('sticky-inset-action'),
            width: 100,
            height: 44,
          ),
        ),
      ),
    ),
  );
}

Widget _buildSelectionSummaryHarness({required bool expanded}) {
  return MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: AppSelectionSummary(
        expanded: expanded,
        items: const [
          AppSelectionSummaryItem(label: '年級', value: '大三'),
          AppSelectionSummaryItem(label: '系所', value: '資訊工程學系'),
        ],
      ),
    ),
  );
}

void _doNothing() {}
