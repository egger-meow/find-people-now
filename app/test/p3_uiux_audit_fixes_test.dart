import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:find_people_now/activities/activity_detail_providers.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/activities/my_activities_providers.dart';
import 'package:find_people_now/activities/my_activities_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/auth/otp_login_screen.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_location_option.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/profile/profile_screen.dart';
import 'package:find_people_now/rpc/activity_rpc.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_button.dart';
import 'package:find_people_now/widgets/app_card.dart';

SupabaseClient _createDummyClient() {
  return SupabaseClient(
    'https://mock.supabase.co',
    'mock-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

AppUser _createTestUser() {
  return AppUser(
    id: 'test-user-id',
    email: 'student@nycu.edu.tw',
    school: SCHOOL.NYCU,
    displayName: '小晴',
    avatarUrl: '',
    bio: '喜歡打羽球、喝咖啡',
    createdAt: DateTime(2025, 1, 1),
    department: '資工系',
    degreeLevel: DEGREE_LEVEL.UNDERGRAD,
    contactLine: 'sunny_line',
  );
}

void main() {
  group('P3 UI/UX Audit Fixes - Polish & Visual Hierarchy (F05, F33, F37)', () {
    testWidgets('F05: OtpLoginScreen presents concrete activity examples in subtitle', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const OtpLoginScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('敢不敢揪'), findsOneWidget);
      expect(
        find.text('羽球、讀書、桌遊，找到現在也想一起的同學。'),
        findsOneWidget,
      );
    });

    testWidgets('F33: ProfileScreen title is 個人, aligning with bottom nav label', (tester) async {
      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top AppBar title should be '個人', not '帳戶'
      expect(find.text('個人'), findsOneWidget);
      expect(find.text('帳戶'), findsNothing);
    });

    testWidgets('F33: Achievement badges render explicit status chips without low opacity', (tester) async {
      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({
                AchievementBadge.firstActivity,
                AchievementBadge.punctual,
              }),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check section header
      expect(find.text('成就徽章'), findsOneWidget);
      expect(find.text('點擊查看條件'), findsOneWidget);

      // Check all 4 badge labels
      for (final badge in AchievementBadge.values) {
        expect(find.text(badge.label), findsOneWidget);
      }

      // Check explicit status chips: 2 earned ('已達成') and 2 unearned ('未達成')
      expect(find.text('已達成'), findsNWidgets(2));
      expect(find.text('未達成'), findsNWidgets(2));

      // Confirm there is NO Opacity widget wrapping badges with 0.35 opacity
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
      for (final op in opacities) {
        expect(op.opacity, isNot(closeTo(0.35, 0.01)));
      }
    });

    test('F33: AchievementBadge criteria strictly reflect SQL RPC database rules', () {
      // 依據 supabase/migrations/20260801160300_account_deleted_guard_new_rpcs.sql:270:
      // FIRST_ACTIVITY: v_attended >= 1
      // PUNCTUAL: v_attended >= 3 and v_no_show = 0
      // GREAT_COMPANY: v_mutual_count >= 1
      // ENTHUSIASTIC_ORGANIZER: v_organized >= 3
      expect(AchievementBadge.firstActivity.criteria, '完成至少 1 筆成團活動出席報到');
      expect(AchievementBadge.punctual.criteria, '累計至少 3 次活動出席紀錄，且無缺席紀錄');
      expect(AchievementBadge.greatCompany.criteria, '活動結束後，至少一次雙方互相投票願意再約');
      expect(AchievementBadge.enthusiasticOrganizer.criteria, '至少 3 筆自己發起且成功成團配對的需求');
    });

    testWidgets('F33: Tapping a badge opens bottom sheet with icon, status, and criteria, and can be dismissed via explicit close button', (tester) async {
      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on unearned badge '準時好車友'
      await tester.tap(find.text('準時好車友'));
      await tester.pumpAndSettle();

      // Bottom sheet should display criteria and status
      expect(find.text('解鎖條件'), findsOneWidget);
      expect(find.text('累計至少 3 次活動出席紀錄，且無缺席紀錄'), findsOneWidget);
      expect(find.widgetWithText(AppButton, '關閉'), findsOneWidget);
      expect(find.byTooltip('關閉'), findsOneWidget);

      // Tap '關閉' to dismiss sheet
      await tester.tap(find.widgetWithText(AppButton, '關閉'));
      await tester.pumpAndSettle();
      expect(find.text('解鎖條件'), findsNothing);
    });

    testWidgets('F33: 驗證 200% (2.0) 字級與短螢幕 (844x390 橫向) 下徽章底層面板可捲動無溢出', (tester) async {
      tester.view.physicalSize = const Size(844 * 2.0, 390 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2.0),
              ),
              child: child!,
            ),
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 確保徽章進入畫面後點擊開啟面板
      await tester.ensureVisible(find.text('準時好車友'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('準時好車友'));
      await tester.pumpAndSettle();

      expect(find.text('解鎖條件'), findsOneWidget);
      // 確保底層面板具備 SingleChildScrollView 捲動保護
      final scrollFinder = find.ancestor(
        of: find.text('解鎖條件'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollFinder, findsOneWidget);

      // 確保在 200% 字級與短螢幕下無任何 RenderFlex 溢出
      expect(tester.takeException(), isNull);

      // 捲動至關閉按鈕並點擊，確認可正常收合
      final sheetScrollable = find.descendant(
        of: scrollFinder,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.widgetWithText(AppButton, '關閉'),
        50.0,
        scrollable: sheetScrollable,
      );
      await tester.tap(find.widgetWithText(AppButton, '關閉'));
      await tester.pumpAndSettle();
      expect(find.text('解鎖條件'), findsNothing);
    });

    testWidgets('F33: SegmentedButton in ThemeModeSection has showSelectedIcon disabled to prevent wrapping', (tester) async {
      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final segmentedFinder = find.byType(SegmentedButton<ThemeMode>);
      expect(segmentedFinder, findsOneWidget);
      final segmented = tester.widget<SegmentedButton<ThemeMode>>(segmentedFinder);
      expect(segmented.showSelectedIcon, isFalse);
    });

    testWidgets('F37: Surface hierarchy unites reliability/badges and legal/logout in common ancestor cards without nesting', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Section labels
      expect(find.text('信譽與成就'), findsOneWidget);
      expect(find.text('設定'), findsOneWidget);
      expect(find.text('說明與回饋'), findsOneWidget);
      expect(find.text('法律與帳號'), findsOneWidget);

      // 驗證共用卡片祖先：法律條款與登出在同一個 AppCard 容器內，非孤立零散卡片
      final logoutTile = find.widgetWithText(ListTile, '登出');
      final termsTile = find.widgetWithText(ListTile, '服務條款');
      final privacyTile = find.widgetWithText(ListTile, '隱私權政策');
      final legalCard = find.ancestor(of: logoutTile, matching: find.byType(AppCard));
      expect(legalCard, findsOneWidget);
      expect(find.descendant(of: legalCard, matching: termsTile), findsOneWidget);
      expect(find.descendant(of: legalCard, matching: privacyTile), findsOneWidget);

      // 驗證共用卡片祖先：可信度等級與成就徽章在同一個 AppCard 容器內
      final reliabilityTierText = find.textContaining('可信度等級');
      final badgesHeader = find.text('成就徽章');
      final trustCard = find.ancestor(of: reliabilityTierText, matching: find.byType(AppCard));
      expect(trustCard, findsOneWidget);
      expect(find.descendant(of: trustCard, matching: badgesHeader), findsOneWidget);

      // 驗證設定區塊：外觀設定與更多資料在同一個 AppCard 容器內
      final themeHeader = find.text('外觀');
      final moreInfoHeader = find.text('更多資料');
      final settingsCard = find.ancestor(of: themeHeader, matching: find.byType(AppCard));
      expect(settingsCard, findsOneWidget);
      expect(find.descendant(of: settingsCard, matching: moreInfoHeader), findsOneWidget);

      // 驗證卡片無巢狀（零「卡片包卡片」）：沒有任何 AppCard 的祖先也是 AppCard
      expect(find.descendant(of: find.byType(AppCard), matching: find.byType(AppCard)), findsNothing);
    });

    testWidgets('F37: ActivityDetailScreen maintains flat card hierarchy with zero nested cards across both location and member tabs', (tester) async {
      final now = DateTime(2026, 10, 4, 12, 0);
      final testActivity = Activity(
        id: 'act-card-hierarchy-test',
        activityTypeId: 'badminton',
        startTime: now.add(const Duration(hours: 2)),
        estimatedEndTime: now.add(const Duration(hours: 4)),
        status: ACTIVITY_STATUS.MATCHED,
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
      final testOption = ActivityLocationOption(
        id: 'loc-1',
        activityId: testActivity.id,
        customName: '交大綜合一館羽球場',
        proposedBy: 'user-me',
        createdAt: now,
      );
      final testMemberMe = MemberRosterEntry(
        userId: 'user-me',
        sourceRequestId: 'req-1',
        status: ACTIVITY_MEMBER_STATUS.JOINED,
        displayName: '小明',
        avatarUrl: '',
        contacts: ActivityContactDetails(contactLine: 'ming_line'),
        school: SCHOOL.NYCU,
        department: '資工系',
        degreeLevel: DEGREE_LEVEL.UNDERGRAD,
        bio: '喜歡打羽球',
        reliabilityTier: ReliabilityTier.trusted,
        meetingHint: '藍色球拍袋',
        arrivedAt: now.add(const Duration(minutes: 5)),
        vibeTags: const ['好相處'],
        studyTarget: '',
      );
      final testMemberFriend = MemberRosterEntry(
        userId: 'user-friend',
        sourceRequestId: 'req-2',
        status: ACTIVITY_MEMBER_STATUS.JOINED,
        displayName: '小晴',
        avatarUrl: '',
        contacts: ActivityContactDetails(contactLine: 'sunny_line'),
        school: SCHOOL.NYCU,
        department: '外文系',
        degreeLevel: DEGREE_LEVEL.UNDERGRAD,
        bio: '新手友善',
        reliabilityTier: ReliabilityTier.normal,
        meetingHint: '穿白色球衣',
        arrivedAt: null,
        vibeTags: const ['熱血'],
        studyTarget: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            currentUserIdProvider.overrideWithValue('user-me'),
            activityStreamProvider(testActivity.id).overrideWith((ref) => Stream.value(testActivity)),
            activityTypeByIdProvider('badminton').overrideWith((ref) async => testType),
            activityLocationOptionsStreamProvider(testActivity.id).overrideWith((ref) => Stream.value([testOption])),
            activityLocationVotesStreamProvider(testActivity.id).overrideWith((ref) => Stream.value([])),
            approvedLocationsProvider((testActivity.school, testActivity.campus)).overrideWith((ref) async => []),
            activityMeetingPointUpdatesStreamProvider(testActivity.id).overrideWith((ref) => Stream.value([])),
            activityMeetingPointStreamProvider(testActivity.id).overrideWith((ref) => Stream.value(null)),
            activityMemberRosterProvider(testActivity.id).overrideWith((ref) async => [testMemberMe, testMemberFriend]),
            activityArrivalStreamProvider(testActivity.id).overrideWith((ref) => const AsyncData({})),
            activityVibeTagsStreamProvider(testActivity.id).overrideWith((ref) => const AsyncData({})),
            activityMeetingHintStreamProvider(testActivity.id).overrideWith((ref) => const AsyncData({})),
            ownCompletionReportProvider(testActivity.id).overrideWith((ref) async => null),
            ownRematchVotesProvider(testActivity.id).overrideWith((ref) async => {}),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: ActivityDetailScreen(activityId: testActivity.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 地點分頁驗證：所有 AppCard 均為平級，不存在「卡片包卡片」的巢狀層級
      expect(find.text('地點與集合'), findsOneWidget);
      expect(find.text('交大綜合一館羽球場'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppCard), matching: find.byType(AppCard)), findsNothing);

      // 2. 切換至成員分頁驗證
      await tester.tap(find.text('成員與聯絡'));
      await tester.pumpAndSettle();

      // 驗證成員資料正確呈現
      expect(find.text('小明（你）'), findsOneWidget);
      expect(find.text('小晴'), findsOneWidget);
      expect(find.byType(ActivityMemberCard), findsNWidgets(2));

      // 驗證成員分頁下所有 AppCard 亦為平級，不存在巢狀卡片
      expect(find.descendant(of: find.byType(AppCard), matching: find.byType(AppCard)), findsNothing);

      // 3. 展開成員卡片，驗證展開狀態下依然保持零卡片巢狀
      await tester.ensureVisible(find.text('小晴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小晴'));
      await tester.pumpAndSettle();
      expect(find.text('穿白色球衣'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppCard), matching: find.byType(AppCard)), findsNothing);
    });

    testWidgets('F35: 驗證 200% (2.0) 字級下 OtpLoginScreen 校園徽章與表單自適應換列無溢出', (tester) async {
      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2.0),
              ),
              child: child!,
            ),
            home: const Scaffold(body: OtpLoginScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('敢不敢揪'), findsOneWidget);
      expect(find.text('羽球、讀書、桌遊，找到現在也想一起的同學。'), findsOneWidget);
      expect(find.text('陽明交大 / 清華 校園即刻揪團'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F35: 驗證 200% (2.0) 字級下 ActivityDetailNavigation 導覽分段無 FittedBox 並自然展開折行', (tester) async {
      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: ActivityDetailNavigation(
              index: 0,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('地點與集合'), findsOneWidget);
      expect(find.text('成員與聯絡'), findsOneWidget);
      // 確保沒有 FittedBox 包裹文字強制將其縮小回原尺寸
      expect(find.ancestor(of: find.text('地點與集合'), matching: find.byType(FittedBox)), findsNothing);
      expect(find.ancestor(of: find.text('成員與聯絡'), matching: find.byType(FittedBox)), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F35: 驗證 200% (2.0) 字級下 MyActivitiesScreen 分段控制無 FittedBox', (tester) async {
      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myActivityListProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2.0),
              ),
              child: child!,
            ),
            home: const MyActivitiesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('進行中'), findsOneWidget);
      expect(find.text('已結束'), findsOneWidget);
      expect(find.ancestor(of: find.text('進行中'), matching: find.byType(FittedBox)), findsNothing);
      expect(find.ancestor(of: find.text('已結束'), matching: find.byType(FittedBox)), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F35: 驗證 200% (2.0) 字級下 ProfileScreen 外觀主題控制無 FittedBox 且正常呈現', (tester) async {
      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final user = _createTestUser();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
            myAppUserProvider.overrideWith((ref) => Future.value(user)),
            myReliabilityProvider.overrideWith(
              (ref) => Future.value(
                MyReliability(tier: ReliabilityTier.trusted, isNewUser: false),
              ),
            ),
            myBadgesProvider.overrideWith(
              (ref) => Future.value({AchievementBadge.firstActivity}),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2.0),
              ),
              child: child!,
            ),
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('跟隨系統'), 100);
      expect(find.text('跟隨系統'), findsOneWidget);
      expect(find.ancestor(of: find.text('跟隨系統'), matching: find.byType(FittedBox)), findsNothing);
      final exc = tester.takeException();
      expect(exc, isNull);
    });
  });
}
