import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/onboarding/onboarding_overlay.dart';
import 'package:find_people_now/theme/app_theme.dart';

AppUser _createUser({DateTime? onboardingSeenAt}) {
  return AppUser(
    id: 'test-user-onboarding',
    email: 'tester@nycu.edu.tw',
    school: SCHOOL.NYCU,
    displayName: '測試者',
    avatarUrl: 'https://avatar/1',
    bio: '自我介紹',
    degreeLevel: DEGREE_LEVEL.UNDERGRAD,
    createdAt: DateTime(2026),
    onboardingSeenAt: onboardingSeenAt,
  );
}

SupabaseClient _createDummyClient() {
  return SupabaseClient(
    'https://mock.supabase.co',
    'mock-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

void main() {
  testWidgets('OnboardingGate shows dialog when onboardingSeenAt is null and stays within bounds', (tester) async {
    // Simulate iPhone SE / narrow screen: 320x568
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    final user = _createUser(onboardingSeenAt: null);
    final dummyClient = _createDummyClient();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(dummyClient),
          myAppUserProvider.overrideWith((ref) async => user),
          currentUserIdProvider.overrideWith((ref) => user.id),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: OnboardingGate(
              child: Center(child: Text('首頁內容')),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Dialog should be presented
    expect(find.text('選活動與時間'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);

    // Tap "下一步" -> page 2
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('等配對，也能邀朋友'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);

    // Tap "下一步" -> page 3
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('成團後約地點、報到'), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('開始使用'), findsOneWidget);

    // Tap "開始使用" -> dismisses
    await tester.tap(find.text('開始使用'));
    await tester.pumpAndSettle();

    expect(find.text('首頁內容'), findsOneWidget);

    // No RenderFlex overflow
    expect(errors.where((e) => e.toString().contains('overflowed')), isEmpty);
  });

  testWidgets('Onboarding dialog survives 2.0 text scale and landscape short height without overflow', (tester) async {
    // Landscape short screen: 640x360 with 2.0 text scale
    tester.view.physicalSize = const Size(640 * 2, 360 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    final user = _createUser(onboardingSeenAt: null);
    final dummyClient = _createDummyClient();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(dummyClient),
          myAppUserProvider.overrideWith((ref) async => user),
          currentUserIdProvider.overrideWith((ref) => user.id),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: const Scaffold(
            body: OnboardingGate(
              child: Center(child: Text('首頁內容')),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verification: dialog is shown and buttons are reachable
    expect(find.text('選活動與時間'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(errors.where((e) => e.toString().contains('overflowed')), isEmpty);

    // Tap skip (close icon)
    await tester.tap(find.byTooltip('跳過'));
    await tester.pumpAndSettle();

    // Dialog is dismissed
    expect(find.text('選活動與時間'), findsNothing);
    expect(find.text('首頁內容'), findsOneWidget);
  });

  testWidgets('OnboardingGate allows tapping bottom navigation and underlying widgets without ModalBarrier interception', (tester) async {
    final user = _createUser(onboardingSeenAt: null);
    final dummyClient = _createDummyClient();
    var underlyingTapped = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(dummyClient),
          myAppUserProvider.overrideWith((ref) async => user),
          currentUserIdProvider.overrideWith((ref) => user.id),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: OnboardingGate(
              child: Stack(
                children: [
                  const Align(
                    alignment: Alignment.center,
                    child: Text('首頁探索清單'),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: ElevatedButton(
                        onPressed: () => underlyingTapped++,
                        child: const Text('底層導覽按鈕'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Both floating card and underlying button are in the tree
    expect(find.text('選活動與時間'), findsOneWidget);
    expect(find.text('底層導覽按鈕'), findsOneWidget);

    // Tap underlying button without modal barrier intercepting
    await tester.tap(find.text('底層導覽按鈕'));
    await tester.pumpAndSettle();

    // The underlying action succeeded while the card is still visible
    expect(underlyingTapped, 1);
    expect(find.text('選活動與時間'), findsOneWidget);
  });

  testWidgets('Onboarding floating card can be dismissed via upward swipe gesture', (tester) async {
    final user = _createUser(onboardingSeenAt: null);
    final dummyClient = _createDummyClient();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(dummyClient),
          myAppUserProvider.overrideWith((ref) async => user),
          currentUserIdProvider.overrideWith((ref) => user.id),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: OnboardingGate(
              child: Center(child: Text('首頁內容')),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('選活動與時間'), findsOneWidget);

    // Swipe up on the card
    await tester.drag(find.text('選活動與時間'), const Offset(0, -300));
    await tester.pumpAndSettle();

    // The card is dismissed
    expect(find.text('選活動與時間'), findsNothing);
    expect(find.text('首頁內容'), findsOneWidget);
  });
}
