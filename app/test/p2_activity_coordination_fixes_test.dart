import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_providers.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_location_option.dart';
import 'package:find_people_now/generated/activity_location_vote.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/location.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart' show activityTypesProvider;
import 'package:find_people_now/rpc/auth_profile_rpc.dart' show ReliabilityTier;
import 'package:find_people_now/theme/app_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    // 5. On Section 1 (Members tab), ONGOING with options -> 返回地點頁參與投票 (且不得出現 查看成員與聯絡)
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.ONGOING,
            hasLocationOptions: true,
            sectionIndex: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返回地點頁參與投票'), findsOneWidget);
    expect(find.text('查看成員與聯絡'), findsNothing);
    expect(find.byIcon(Icons.place_rounded), findsOneWidget);

    // 6. On Section 0 (Location tab), ONGOING with options -> 查看成員與聯絡
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.ONGOING,
            hasLocationOptions: true,
            sectionIndex: 0,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看成員與聯絡'), findsOneWidget);
    expect(find.byIcon(Icons.groups_rounded), findsOneWidget);

    // 7. On Section 0 with location error -> 重新載入地點資訊
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDetailStickyAction(
            status: ACTIVITY_STATUS.ONGOING,
            hasLocationOptions: true,
            locationError: true,
            sectionIndex: 0,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重新載入地點資訊'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('F25: ActivityDetailScreen 實際點擊驗證：地點載入失敗重載留在地點頁、成員頁點擊切回地點頁', (tester) async {
    final now = DateTime(2026, 10, 4, 12, 0);
    final testActivity = Activity(
      id: 'act-coord-tap-test',
      activityTypeId: 'badminton',
      startTime: now.add(const Duration(hours: 2)),
      estimatedEndTime: now.add(const Duration(hours: 4)),
      status: ACTIVITY_STATUS.ONGOING,
      contactVisibleUntil: now.add(const Duration(days: 1)),
      createdAt: now,
      school: SCHOOL.NYCU,
      campus: '光復',
    );

    final testType = ActivityType(
      id: 'badminton',
      name: '羽球',
      status: ACTIVITY_TYPE_STATUS.APPROVED,
      createdAt: now,
      skillLevelEnabled: false,
      sortOrder: 1,
      levelSystem: LEVEL_SYSTEM.NONE,
      aliases: const [],
    );

    final testMember = MemberRosterEntry(
      userId: 'user-me',
      sourceRequestId: 'req-1',
      status: ACTIVITY_MEMBER_STATUS.JOINED,
      displayName: '小明',
      avatarUrl: '',
      contacts: null,
      school: SCHOOL.NYCU,
      department: '資工系',
      degreeLevel: DEGREE_LEVEL.UNDERGRAD,
      bio: '',
      reliabilityTier: ReliabilityTier.trusted,
      meetingHint: '',
      arrivedAt: now.add(const Duration(minutes: 5)),
      vibeTags: const [],
      studyTarget: '',
    );

    final testOption = ActivityLocationOption(
      id: 'loc-opt-tap-1',
      activityId: testActivity.id,
      customName: '交大綜合一館羽球場',
      proposedBy: 'user-me',
      createdAt: now,
    );

    var optionsReloadCount = 0;
    var simulateLocationError = true;

    Widget buildSubject() {
      return ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-me'),
          activityStreamProvider(testActivity.id).overrideWith(
            (ref) => Stream.value(testActivity),
          ),
          activityLocationOptionsStreamProvider(testActivity.id).overrideWith(
            (ref) {
              optionsReloadCount++;
              if (simulateLocationError) {
                return Stream.error(Exception('Simulated location error'));
              }
              return Stream.value([testOption]);
            },
          ),
          activityLocationVotesStreamProvider(testActivity.id).overrideWith(
            (ref) => Stream.value(<ActivityLocationVote>[]),
          ),
          approvedLocationsProvider((testActivity.school, testActivity.campus)).overrideWith(
            (ref) async => <Location>[],
          ),
          ownCompletionReportProvider(testActivity.id).overrideWith(
            (ref) async => null,
          ),
          activityMemberRosterProvider(testActivity.id).overrideWith(
            (ref) async => [testMember],
          ),
          activityArrivalStreamProvider(testActivity.id).overrideWithValue(
            AsyncData({'user-me': now.add(const Duration(minutes: 5))}),
          ),
          activityVibeTagsStreamProvider(testActivity.id).overrideWith(
            (ref) => const AsyncData(<String, List<String>>{}),
          ),
          activityMeetingHintStreamProvider(testActivity.id).overrideWith(
            (ref) => const AsyncData(<String, String?>{}),
          ),
          activityMeetingPointUpdatesStreamProvider(testActivity.id).overrideWith(
            (ref) => Stream.value(const []),
          ),
          activityTypesProvider.overrideWith((ref) async => [testType]),
          supabaseClientProvider.overrideWithValue(
            SupabaseClient(
              'http://127.0.0.1:65535',
              'test-anon-key',
              authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: ActivityDetailScreen(activityId: testActivity.id),
        ),
      );
    }

    // === 驗證 1：地點載入失敗時，點「重新載入地點資訊」留在地點頁且重新載入 ===
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    // 首屏位於地點頁 (Section 0)
    expect(find.byKey(const Key('location-tab')), findsOneWidget);
    expect(find.text('重新載入地點資訊'), findsOneWidget);
    final initialReloadCount = optionsReloadCount;
    expect(initialReloadCount, greaterThan(0));

    // 點擊「重新載入地點資訊」
    simulateLocationError = false;
    await tester.tap(find.text('重新載入地點資訊'));
    await tester.pumpAndSettle();

    // 斷言：仍然留在地點頁 (Section 0)，沒有錯誤切到成員頁，且 optionsReloadCount 遞增
    expect(find.byKey(const Key('location-tab')), findsOneWidget);
    expect(optionsReloadCount, greaterThan(initialReloadCount));

    // === 驗證 2：進行中且已報到時，成員頁顯示「返回地點頁參與投票」且點擊切回地點頁 ===
    // 目前已有候選地點，在 Section 0 下主按鈕為「查看成員與聯絡」
    expect(find.text('查看成員與聯絡'), findsOneWidget);
    await tester.tap(find.text('查看成員與聯絡'));
    await tester.pumpAndSettle();

    // 已切換至成員頁 (Section 1)
    expect(find.byType(MembersTab), findsOneWidget);
    // 斷言：成員頁底部按鈕顯示「返回地點頁參與投票」，絕不再出現「查看成員與聯絡」
    expect(find.text('返回地點頁參與投票'), findsOneWidget);
    expect(find.text('查看成員與聯絡'), findsNothing);

    // 點擊「返回地點頁參與投票」
    await tester.tap(find.text('返回地點頁參與投票'));
    await tester.pumpAndSettle();

    // 斷言：成功切回地點頁 (Section 0)
    expect(find.byKey(const Key('location-tab')), findsOneWidget);
  });
}
