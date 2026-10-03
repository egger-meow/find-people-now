import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/widgets/activity_demand_detail_sheet.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/match/widgets/pinned_active_status_card.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/widgets/campus_demands_section.dart';

void main() {
  group('P1 UI/UX Audit Fixes Regression Tests', () {
    test('F34: AppColors.forestGreen contrast ratio against white is >= 4.5:1 (WCAG 2.1 sRGB exponent 2.4)', () {
      const color = AppColors.forestGreen;
      // Calculate relative luminance according to IEC 61966-2-1 / WCAG 2.1 specs using exponent 2.4
      double channelLuminance(int channel) {
        final val = channel / 255.0;
        return val <= 0.04045
            ? val / 12.92
            : (val + 0.055) / 1.055 > 0
                ? (math.pow((val + 0.055) / 1.055, 2.4)).toDouble()
                : 0.0;
      }

      final r = channelLuminance((color.r * 255.0).round());
      final g = channelLuminance((color.g * 255.0).round());
      final b = channelLuminance((color.b * 255.0).round());
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

      // White relative luminance is 1.0
      final contrastWithWhite = (1.0 + 0.05) / (lum + 0.05);

      // #036949 has relative luminance ~0.1063, yielding contrast ratio ~6.72:1 against white
      expect(
        contrastWithWhite,
        greaterThanOrEqualTo(4.5),
        reason: 'forestGreen (#036949) must satisfy WCAG AA 4.5:1 contrast against white text',
      );
      expect(
        contrastWithWhite,
        closeTo(6.72, 0.05),
        reason: 'IEC 61966-2-1 standard calculation yields ~6.72:1 contrast ratio',
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

    testWidgets('F08: Demand filter chips retain full labels without single-character clipping on 320px width and 1.5x scaler', (tester) async {
      tester.view.physicalSize = const Size(320 * 2.0, 740 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            campusDemandsProvider((SCHOOL.NYCU, '光復校區')).overrideWith(
              (ref) => Stream.value([]),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: Scaffold(
                body: CampusDemandsSection(
                  school: SCHOOL.NYCU,
                  campus: '光復校區',
                  availableCampuses: const ['光復校區'],
                  onSelectCampus: (_) {},
                  onSelectDemand: (_) {},
                  onCreateNewRequest: () {},
                  onSetAlert: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final label in ['全部', '現在', '今天', '明天']) {
        final textFinder = find.text(label);
        expect(textFinder, findsOneWidget);
        final size = tester.getSize(textFinder);
        // At 1.5x text scaler, a 2-character Chinese string must be significantly wider than a single character (single char ~21px, 2 chars ~40px+).
        // If clipped to single character, size.width would be <= 22px.
        expect(size.width, greaterThan(30.0), reason: '$label must render both characters without clipping');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('F08: ActivityDetailNavigation segments render multi-character labels without text clipping at 320px width', (tester) async {
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
                width: 300,
                child: ActivityDetailNavigation(
                  index: 0,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final label in ['地點與集合', '成員與聯絡']) {
        final textFinder = find.text(label);
        expect(textFinder, findsOneWidget);
        final size = tester.getSize(textFinder);
        expect(size.width, greaterThan(50.0), reason: '$label must render completely without truncation');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('F25: ActivityDetailStickyAction on Section 0 shows single primary 提出地點 when no candidates exist', (tester) async {
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
      expect(find.text('前往提出候選地點'), findsNothing);
    });
  });
}
