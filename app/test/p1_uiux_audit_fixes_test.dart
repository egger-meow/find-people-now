import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/widgets/activity_demand_detail_sheet.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/match/widgets/pinned_active_status_card.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_button.dart';

void main() {
  group('P1 UI/UX Audit Fixes Regression Tests', () {
    test('F34: AppColors.forestGreen contrast ratio against white is >= 4.5:1', () {
      const color = AppColors.forestGreen;
      // Calculate relative luminance according to WCAG 2.1 specs
      double channelLuminance(int channel) {
        final val = channel / 255.0;
        return val <= 0.03928 ? val / 12.92 : ((val + 0.055) / 1.055) * ((val + 0.055) / 1.055);
      }

      final r = channelLuminance((color.r * 255.0).round());
      final g = channelLuminance((color.g * 255.0).round());
      final b = channelLuminance((color.b * 255.0).round());
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

      // White luminance is 1.0
      final contrastWithWhite = (1.0 + 0.05) / (lum + 0.05);

      expect(
        contrastWithWhite,
        greaterThanOrEqualTo(4.5),
        reason: 'forestGreen (#047857) must satisfy WCAG AA 4.5:1 contrast against white text',
      );
    });

    testWidgets('F07: CampusDemandCardWidget renders title and time badge without vertical collapse on 320px width', (tester) async {
      final demand = CampusDemandCard(
        activityTypeId: 'act-badminton',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 10, 3, 18, 0),
        latestStart: DateTime(2026, 10, 3, 20, 0),
        sportLevel: 'LEVEL_1_5',
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 3,
        requestCount: 2,
      );

      tester.view.physicalSize = const Size(320 * 2.0, 740 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: CampusDemandCardWidget(
                  demand: demand,
                  summaryHeadline: '今天 3 人在揪羽球',
                  relativeNow: DateTime(2026, 10, 3, 12, 0),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Title renders as a clean headline
      expect(find.text('今天 3 人在揪羽球'), findsOneWidget);
      // Time slot is rendered cleanly as a chip
      expect(find.textContaining('18:00'), findsOneWidget);
      // No RenderFlex overflow
      expect(tester.takeException(), isNull);
    });

    testWidgets('F11: PinnedActiveStatusCard avoids overpromising reserved seats for requesting status', (tester) async {
      final mockRequest = MatchRequest(
        id: 'req-requesting-1',
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
          theme: AppTheme.light,
          home: Scaffold(
            body: PinnedActiveStatusCard(
              request: mockRequest,
              activity: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('你正在配對中'), findsOneWidget);
      expect(find.text('狀態：已收到需求，正在撮合中'), findsOneWidget);
      expect(find.textContaining('已為你保留名額'), findsNothing);
    });

    testWidgets('F13: ActivityDemandDetailSheet has pinned action buttons and accessible close button', (tester) async {
      final demand = CampusDemandCard(
        activityTypeId: 'act-study',
        activityTypeName: '讀書',
        campus: '光復校區 圖書館',
        earliestStart: DateTime(2026, 10, 3, 14, 0),
        latestStart: DateTime(2026, 10, 3, 16, 0),
        sportLevel: null,
        sportLevelRating: null,
        studyTarget: '微積分期中考衝刺',
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 2,
        requestCount: 1,
      );

      bool participated = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ActivityDemandDetailSheet(
              demand: demand,
              canParticipate: true,
              onParticipate: () => participated = true,
              onCustomize: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Close button with accessible tooltip exists
      expect(find.byTooltip('關閉'), findsOneWidget);

      // Primary participate button exists and is clickable directly
      final participateBtn = find.widgetWithText(AppButton, '以相容條件加入配對');
      expect(participateBtn, findsOneWidget);
      await tester.tap(participateBtn);
      await tester.pumpAndSettle();
      expect(participated, isTrue);
    });
  });
}
