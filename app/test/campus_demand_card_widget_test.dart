import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/match/widgets/activity_demand_detail_sheet.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/widgets/app_button.dart';

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

  testWidgets('renders activity name, time slot, chips and honest signal',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusDemandCardWidget(
            demand: mockDemand,
            relativeNow: DateTime(2026, 9, 16, 12, 0),
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('羽球'), findsOneWidget);
    expect(find.textContaining('今天'), findsOneWidget);
    expect(find.textContaining('18:00'), findsOneWidget);
    expect(find.text('光復校區'), findsOneWidget);
    expect(find.textContaining('2 人在找球友'), findsOneWidget);
    expect(find.text('查看詳情'), findsOneWidget);

    await tester.tap(find.text('查看詳情'));
    expect(tapped, isTrue);
  });

  testWidgets('detail sheet displays criteria and triggers onParticipate',
      (tester) async {
    var participated = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showActivityDemandDetailSheet(
                context,
                demand: mockDemand,
                canParticipate: true,
                onParticipate: () => participated = true,
                onCustomize: () {},
                relativeNow: DateTime(2026, 9, 16, 12, 0),
              ),
              child: const Text('Open Sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    expect(find.text('羽球'), findsWidgets);
    expect(find.text('光復校區'), findsWidgets);
    expect(find.textContaining('成團前全員匿名'), findsOneWidget);
    expect(find.text('以相容條件加入配對'), findsOneWidget);

    await tester.tap(find.text('以相容條件加入配對'));
    expect(participated, isTrue);
  });

  testWidgets('detail sheet triggers onCustomize', (tester) async {
    var customized = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showActivityDemandDetailSheet(
                context,
                demand: mockDemand,
                canParticipate: true,
                onParticipate: () {},
                onCustomize: () => customized = true,
                relativeNow: DateTime(2026, 9, 16, 12, 0),
              ),
              child: const Text('Open Sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('調整條件後發起...'));
    expect(customized, isTrue);
  });

  testWidgets('detail sheet disables participate button when canParticipate is false',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showActivityDemandDetailSheet(
                context,
                demand: mockDemand,
                canParticipate: false,
                disabledReason: '你已有進行中的配對，暫無法加入',
                onParticipate: () {},
                onCustomize: () {},
                relativeNow: DateTime(2026, 9, 16, 12, 0),
              ),
              child: const Text('Open Sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('你已有進行中的配對，暫無法加入'), findsOneWidget);
    final participateButton = tester.widget<AppButton>(
      find.widgetWithText(AppButton, '以相容條件加入配對'),
    );
    expect(participateButton.onPressed, isNull);
  });
}

