import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/widgets/campus_demands_section.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/widgets/skeleton.dart';

void main() {
  final mockDemand = CampusDemandCard(
    activityTypeId: 'act-1',
    activityTypeName: '羽球',
    campus: '光復校區',
    earliestStart: DateTime(2026, 9, 16, 18, 0),
    latestStart: DateTime(2026, 9, 16, 20, 0),
    sportLevel: 'LEVEL_1_5',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 2,
    maxParticipants: 4,
    personCount: 2,
    requestCount: 1,
  );

  testWidgets('renders skeletons during loading state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          campusDemandsProvider.overrideWith(
            (ref, key) => const Stream.empty(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CampusDemandsSection(
              school: SCHOOL.NYCU,
              campus: '光復校區',
              availableCampuses: const ['光復校區', '博愛校區'],
              onSelectCampus: (_) {},
              onSelectDemand: (_) {},
              onCreateNewRequest: () {},
              onSetAlert: () {},
              relativeNow: DateTime(2026, 9, 16, 12, 0),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Skeleton), findsWidgets);
    expect(find.text('校園即時揪團動態'), findsOneWidget);
  });

  testWidgets('renders empty state when no demands available', (tester) async {
    var createNewTapped = false;
    var setAlertTapped = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          campusDemandsProvider.overrideWith(
            (ref, key) => Stream.value([]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CampusDemandsSection(
              school: SCHOOL.NYCU,
              campus: '光復校區',
              availableCampuses: const ['光復校區', '博愛校區'],
              onSelectCampus: (_) {},
              onSelectDemand: (_) {},
              onCreateNewRequest: () => createNewTapped = true,
              onSetAlert: () => setAlertTapped = true,
              relativeNow: DateTime(2026, 9, 16, 12, 0),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.textContaining('目前光復校區還沒有人在揪'), findsOneWidget);
    expect(find.text('自己揪一個'), findsOneWidget);
    expect(find.text('設定時效提醒'), findsOneWidget);

    await tester.tap(find.text('自己揪一個'));
    expect(createNewTapped, isTrue);

    await tester.tap(find.text('設定時效提醒'));
    expect(setAlertTapped, isTrue);
  });

  testWidgets('renders error state and allows retry', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          campusDemandsProvider.overrideWith(
            (ref, key) async* {
              throw Exception('Network error');
            },
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CampusDemandsSection(
              school: SCHOOL.NYCU,
              campus: '光復校區',
              availableCampuses: const ['光復校區', '博愛校區'],
              onSelectCampus: (_) {},
              onSelectDemand: (_) {},
              onCreateNewRequest: () {},
              onSetAlert: () {},
              relativeNow: DateTime(2026, 9, 16, 12, 0),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('暫時無法取得校園揪團動態'), findsOneWidget);
    expect(find.text('重試'), findsOneWidget);
  });

  testWidgets('renders demand list and triggers onSelectDemand', (tester) async {
    CampusDemandCard? selected;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          campusDemandsProvider.overrideWith(
            (ref, key) => Stream.value([mockDemand]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CampusDemandsSection(
              school: SCHOOL.NYCU,
              campus: '光復校區',
              availableCampuses: const ['光復校區', '博愛校區'],
              onSelectCampus: (_) {},
              onSelectDemand: (demand) => selected = demand,
              onCreateNewRequest: () {},
              onSetAlert: () {},
              relativeNow: DateTime(2026, 9, 16, 12, 0),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('羽球'), findsOneWidget);
    expect(find.textContaining('2 人在找球友'), findsOneWidget);

    await tester.tap(find.text('羽球'));
    expect(selected, mockDemand);
  });
}
