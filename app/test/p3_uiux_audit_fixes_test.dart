import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/auth/otp_login_screen.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/profile/profile_screen.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

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

    testWidgets('F33: Tapping a badge opens bottom sheet with icon, status, and criteria', (tester) async {
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
      expect(find.text(AchievementBadge.punctual.criteria), findsOneWidget);
      expect(find.text('活動開始前後準時抵達並完成報到'), findsOneWidget);
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

    testWidgets('F37: Surface hierarchy unites reliability/badges and legal/logout without fragmented cards', (tester) async {
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

      // '登出' is a ListTile inside the legal & account card, not in a lonely separate card
      expect(find.widgetWithText(ListTile, '登出'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '服務條款'), findsOneWidget);
    });
  });
}
