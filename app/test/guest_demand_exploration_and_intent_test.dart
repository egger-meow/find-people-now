import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/create_request_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/widgets/campus_demands_section.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';

void main() {
  final now = DateTime(2026, 9, 16, 12, 0);

  final mockDemand = CampusDemandCard(
    activityTypeId: 'act-1',
    activityTypeName: '羽球',
    campus: '光復',
    earliestStart: DateTime(2026, 9, 16, 18, 0),
    latestStart: DateTime(2026, 9, 16, 20, 0),
    sportLevel: 'LEVEL_1_5',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 2,
    maxParticipants: 4,
    personCount: 2,
    requestCount: 1,
    formedGroupCount: 0,
    formedPersonCount: 0,
  );

  group('CampusDemandsSection privacy suppression & guest states', () {
    testWidgets('renders privacy suppressed empty state when hasSuppressedDemands is true and demands is empty', (tester) async {
      var loginTapped = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            publicCampusDemandsProvider.overrideWith(
              (ref, key) => Future.value(
                const PublicCampusDemandsResult(
                  demands: [],
                  campuses: ['光復', '博愛'],
                  hasSuppressedDemands: true,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復',
                availableCampuses: const ['光復', '博愛'],
                onSelectCampus: (_) {},
                onSelectDemand: (_) {},
                onCreateNewRequest: () {},
                onSetAlert: () {},
                onLoginTap: () => loginTapped = true,
                hasSuppressedDemands: true,
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('目前小樣本需求依隱私原則未公開'), findsOneWidget);
      expect(
        find.textContaining('為避免透過特定時間與地點反推個人身分'),
        findsOneWidget,
      );
      expect(find.text('登入學校信箱'), findsOneWidget);

      await tester.tap(find.text('登入學校信箱'));
      expect(loginTapped, isTrue);
    });

    testWidgets('renders privacy shield badge when demands list has items but hasSuppressedDemands is true', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            publicCampusDemandsProvider.overrideWith(
              (ref, key) => Future.value(
                PublicCampusDemandsResult(
                  demands: [mockDemand],
                  campuses: const ['光復', '博愛'],
                  hasSuppressedDemands: true,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復',
                availableCampuses: const ['光復', '博愛'],
                onSelectCampus: (_) {},
                onSelectDemand: (_) {},
                onCreateNewRequest: () {},
                onSetAlert: () {},
                onLoginTap: () {},
                hasSuppressedDemands: true,
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('部分依隱私保護未公開'), findsOneWidget);
      expect(find.text('羽球'), findsOneWidget);
    });

    testWidgets('guest school switcher allows toggling between schools', (tester) async {
      SCHOOL? selectedSchool;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            publicCampusDemandsProvider.overrideWith(
              (ref, key) => Future.value(
                PublicCampusDemandsResult(
                  demands: [mockDemand],
                  campuses: const ['光復', '博愛'],
                  hasSuppressedDemands: false,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CampusDemandsSection(
                school: SCHOOL.NYCU,
                campus: '光復',
                availableCampuses: const ['光復', '博愛'],
                onSelectCampus: (_) {},
                onSelectDemand: (_) {},
                onCreateNewRequest: () {},
                onSetAlert: () {},
                onSelectSchool: (s) => selectedSchool = s,
                onLoginTap: () {},
                relativeNow: now,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('陽明交大'), findsOneWidget);
      await tester.tap(find.text('陽明交大'));
      await tester.pumpAndSettle();

      expect(find.text('選擇學校'), findsOneWidget);
      expect(find.text('國立清華大學'), findsOneWidget);

      await tester.tap(find.text('國立清華大學'));
      await tester.pumpAndSettle();

      expect(selectedSchool, SCHOOL.NTHU);
    });
  });

  group('PendingDemandJoinIntent logic & lifecycle', () {
    test('isExpired detects expiration accurately', () {
      final validIntent = PendingDemandJoinIntent(
        activityTypeId: 'act-1',
        activityTypeName: '羽球',
        school: SCHOOL.NYCU,
        campus: '光復',
        earliestStart: DateTime(2026, 9, 16, 18, 0),
        latestStart: DateTime(2026, 9, 16, 20, 0),
        minParticipants: 2,
        capturedAt: now,
      );

      expect(validIntent.isExpired(DateTime(2026, 9, 16, 19, 0)), isFalse);
      expect(validIntent.isExpired(DateTime(2026, 9, 16, 20, 1)), isTrue);
    });

    test('PendingDemandJoinIntent round-trip json serialization', () {
      final intent = PendingDemandJoinIntent(
        activityTypeId: 'act-1',
        activityTypeName: '羽球',
        school: SCHOOL.NYCU,
        campus: '光復',
        earliestStart: DateTime(2026, 9, 16, 18, 0),
        latestStart: DateTime(2026, 9, 16, 20, 0),
        minParticipants: 2,
        maxParticipants: 4,
        sportLevel: 'LEVEL_1_5',
        capturedAt: now,
      );

      final json = intent.toJson();
      final restored = PendingDemandJoinIntent.fromJson(json);

      expect(restored.activityTypeId, intent.activityTypeId);
      expect(restored.activityTypeName, intent.activityTypeName);
      expect(restored.school, intent.school);
      expect(restored.campus, intent.campus);
      expect(restored.minParticipants, intent.minParticipants);
      expect(restored.maxParticipants, intent.maxParticipants);
      expect(restored.sportLevel, intent.sportLevel);
    });
  });

  group('CreateRequestScreen Guest Exploration Mode', () {
    testWidgets('renders unauthenticated guest view with welcome banner, demands and login prompt', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue(null),
            campusOptionsProvider.overrideWith(
              (ref, school) => Future.value(const ['光復', '博愛']),
            ),
            publicCampusDemandsProvider.overrideWith(
              (ref, key) => Future.value(
                PublicCampusDemandsResult(
                  demands: [mockDemand],
                  campuses: const ['光復', '博愛'],
                  hasSuppressedDemands: false,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: CreateRequestScreen(
              now: () => now,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Guest welcome banner
      expect(find.text('免登入預覽'), findsOneWidget);
      expect(find.text('100% 匿名活動探索'), findsOneWidget);

      // Demand card
      expect(find.text('羽球'), findsOneWidget);
      expect(find.text('看看條件'), findsOneWidget);

      // Bottom login prompt card
      expect(find.text('登入學校信箱，開始參與或發起活動'), findsOneWidget);
      expect(find.text('使用學校信箱快速登入'), findsOneWidget);
      expect(find.text('安心匿名'), findsOneWidget);
      expect(find.text('校園驗證'), findsOneWidget);
    });
  });
}
