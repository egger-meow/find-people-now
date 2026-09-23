import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/widgets/aggregated_demands_sheet.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/match/widgets/campus_demands_section.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';

void main() {
  final now = DateTime(2026, 9, 23, 14, 0);

  final badminton1 = CampusDemandCard(
    activityTypeId: 'act-badminton',
    activityTypeName: '羽球',
    campus: '光復校區',
    earliestStart: DateTime(2026, 9, 23, 15, 0),
    latestStart: DateTime(2026, 9, 23, 17, 0),
    sportLevel: 'LEVEL_1_5',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 2,
    maxParticipants: 4,
    personCount: 2,
    requestCount: 1,
  );

  final badminton2 = CampusDemandCard(
    activityTypeId: 'act-badminton',
    activityTypeName: '羽球',
    campus: '光復校區',
    earliestStart: DateTime(2026, 9, 23, 18, 0),
    latestStart: DateTime(2026, 9, 23, 20, 0),
    sportLevel: 'LEVEL_3',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 4,
    maxParticipants: 6,
    personCount: 3,
    requestCount: 2,
  );

  final basketball1 = CampusDemandCard(
    activityTypeId: 'act-basketball',
    activityTypeName: '籃球',
    campus: '光復校區',
    earliestStart: DateTime(2026, 9, 23, 16, 0),
    latestStart: DateTime(2026, 9, 23, 18, 0),
    sportLevel: 'CASUAL',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 6,
    maxParticipants: 10,
    personCount: 5,
    requestCount: 1,
  );

  group('formatDemandsLastUpdated', () {
    test('formats within 1 minute as 剛剛更新', () {
      final updated = now.subtract(const Duration(seconds: 30));
      expect(formatDemandsLastUpdated(updated, relativeTo: now), '剛剛更新');
    });

    test('formats minutes ago properly', () {
      final updated = now.subtract(const Duration(minutes: 15));
      expect(formatDemandsLastUpdated(updated, relativeTo: now), '15 分鐘前更新');
    });

    test('formats hours ago properly', () {
      final updated = now.subtract(const Duration(hours: 3));
      expect(formatDemandsLastUpdated(updated, relativeTo: now), '3 小時前更新');
    });

    test('formats past days with date', () {
      final updated = DateTime(2026, 9, 20, 10, 0);
      expect(formatDemandsLastUpdated(updated, relativeTo: now), '9/20 更新');
    });
  });

  group('aggregateDemands & AggregatedDemandGroup', () {
    test('aggregates demands by stable activityTypeId', () {
      final list = [badminton1, basketball1, badminton2];
      final groups = aggregateDemands(list);

      expect(groups.length, 2);
      expect(groups[0].activityTypeId, 'act-badminton');
      expect(groups[0].demands.length, 2);
      expect(groups[0].hasSingleDemand, isFalse);
      expect(groups[0].totalRequests, 3); // 1 + 2

      expect(groups[1].activityTypeId, 'act-basketball');
      expect(groups[1].demands.length, 1);
      expect(groups[1].hasSingleDemand, isTrue);
      expect(groups[1].singlePersonCount, 5);
    });

    test('generates honest summaryHeadline without fabricating unique headcount across groups', () {
      final multiGroup = AggregatedDemandGroup(
        activityTypeId: 'act-badminton',
        activityTypeName: '羽球',
        campus: '光復校區',
        demands: [badminton1, badminton2],
      );

      // Multi-group uses totalRequests rather than summing non-union distinct users
      expect(
        multiGroup.summaryHeadline(DemandTimeFilter.today, relativeNow: now),
        '今天 3 組需求在揪羽球',
      );
      expect(
        multiGroup.summaryHeadline(DemandTimeFilter.now, relativeNow: now),
        '現在 3 組需求在揪羽球',
      );

      final singleGroup = AggregatedDemandGroup(
        activityTypeId: 'act-basketball',
        activityTypeName: '籃球',
        campus: '光復校區',
        demands: [basketball1],
      );
      expect(
        singleGroup.summaryHeadline(DemandTimeFilter.today, relativeNow: now),
        '今天 5 人在揪籃球',
      );
    });
  });

  group('CampusDemandsSection widget aggregation & sheet integration', () {
    testWidgets('renders single demand card for single group and aggregated card for multi group', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            campusDemandsProvider.overrideWith(
              (ref, key) => Stream.value([badminton1, badminton2, basketball1]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復校區',
                availableCampuses: const ['光復校區'],
                onSelectCampus: (_) {},
                onSelectDemand: (_) {},
                onCreateNewRequest: () {},
                onSetAlert: () {},
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // Multi-demand badminton shows aggregated card
      expect(find.byType(AggregatedDemandCardWidget), findsOneWidget);
      expect(find.textContaining('3 組需求在揪羽球'), findsOneWidget);
      expect(find.text('2 組條件'), findsOneWidget);

      // Single-demand basketball shows standard card with summaryHeadline
      expect(find.byType(CampusDemandCardWidget), findsOneWidget);
      expect(find.textContaining('5 人在揪籃球'), findsOneWidget);
    });

    testWidgets('tapping aggregated card opens sheet with selectable condition rows without auto-selecting', (tester) async {
      CampusDemandCard? selectedDemand;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            campusDemandsProvider.overrideWith(
              (ref, key) => Stream.value([badminton1, badminton2]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復校區',
                availableCampuses: const ['光復校區'],
                onSelectCampus: (_) {},
                onSelectDemand: (d) => selectedDemand = d,
                onCreateNewRequest: () {},
                onSetAlert: () {},
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // Tap aggregated card to open sheet
      await tester.tap(find.byType(AggregatedDemandCardWidget));
      await tester.pumpAndSettle();

      expect(find.byType(AggregatedDemandsSheet), findsOneWidget);
      expect(find.textContaining('共 2 組相容時段與程度條件'), findsOneWidget);
      expect(find.text('請點選合適的時段與程度，確認後送出配對'), findsOneWidget);

      // Nothing auto-selected before user tap
      expect(selectedDemand, isNull);

      // Tap the second option (badminton2)
      await tester.tap(find.textContaining('18:00'));
      await tester.pumpAndSettle();

      // Sheet is closed and badminton2 is selected
      expect(find.byType(AggregatedDemandsSheet), findsNothing);
      expect(selectedDemand, badminton2);
    });

    testWidgets('shows stale warning banner when error occurs with cached data', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            campusDemandsProvider.overrideWith(
              (ref, key) => Stream<List<CampusDemandCard>>.multi((controller) {
                // First emit data
                controller.add([badminton1]);
                // Then emit error while keeping previous value
                controller.addError(Exception('Network drop'));
              }),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復校區',
                availableCampuses: const ['光復校區'],
                onSelectCampus: (_) {},
                onSelectDemand: (_) {},
                onCreateNewRequest: () {},
                onSetAlert: () {},
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('連線異常，顯示稍早載入的動態（尚未更新）'), findsOneWidget);
      expect(find.byType(CampusDemandCardWidget), findsOneWidget);
    });
  });
}
