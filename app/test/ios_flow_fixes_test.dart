import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/profile/edit_profile_screen.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  testWidgets('EditProfileScreen has PopScope that guards unsaved modifications', (tester) async {
    final mockUser = AppUser(
      id: 'test-user-id',
      email: 'test@nycu.edu.tw',
      school: SCHOOL.NYCU,
      displayName: 'Alice',
      avatarUrl: '',
      department: '資工系',
      degreeLevel: DEGREE_LEVEL.UNDERGRAD,
      gender: 'FEMALE',
      bio: 'Hello world',
      contactIg: 'alice_ig',
      contactLine: null,
      contactDiscord: null,
      createdAt: DateTime(2026, 9, 1),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myAppUserProvider.overrideWith((ref) async => mockUser),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const EditProfileScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify PopScope exists
    final popScopeFinder = find.byWidgetPredicate((w) => w is PopScope);
    expect(popScopeFinder, findsOneWidget);

    final popScope = tester.widget<PopScope>(popScopeFinder);
    // Initially not dirty -> canPop should be true
    expect(popScope.canPop, isTrue);

    // Modify bio
    final bioField = find.widgetWithText(TextField, 'Hello world');
    expect(bioField, findsOneWidget);
    await tester.enterText(bioField, 'Modified bio text');
    await tester.pump();

    // After editing, popScope should be dirty -> canPop is false
    final dirtyPopScope = tester.widget<PopScope>(popScopeFinder);
    expect(dirtyPopScope.canPop, isFalse);

    // Simulate back navigation
    await Navigator.maybePop(tester.element(popScopeFinder));
    await tester.pumpAndSettle();

    // Confirmation dialog should be presented
    expect(find.text('捨棄未儲存的變更？'), findsOneWidget);
    expect(find.text('捨棄'), findsOneWidget);
    expect(find.text('繼續編輯'), findsOneWidget);

    // Tap "繼續編輯"
    await tester.tap(find.text('繼續編輯'));
    await tester.pumpAndSettle();

    // Should remain on EditProfileScreen
    expect(find.text('編輯個人資料'), findsOneWidget);
  });

  testWidgets('EditProfileScreen guards unsaved modifications on iOS edge swipe-back gesture', (tester) async {
    final mockUser = AppUser(
      id: 'test-user-id',
      email: 'test@nycu.edu.tw',
      school: SCHOOL.NYCU,
      displayName: 'Alice',
      avatarUrl: '',
      department: '資工系',
      degreeLevel: DEGREE_LEVEL.UNDERGRAD,
      gender: 'FEMALE',
      bio: 'Hello world',
      contactIg: 'alice_ig',
      contactLine: null,
      contactDiscord: null,
      createdAt: DateTime(2026, 9, 1),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myAppUserProvider.overrideWith((ref) async => mockUser),
        ],
        child: MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.iOS,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              },
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      CupertinoPageRoute(
                        builder: (_) => const EditProfileScreen(),
                      ),
                    );
                  },
                  child: const Text('Open Edit'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Push EditProfileScreen
    await tester.tap(find.text('Open Edit'));
    await tester.pumpAndSettle();

    expect(find.text('編輯個人資料'), findsOneWidget);

    // Modify bio to make form dirty
    final bioField = find.widgetWithText(TextField, 'Hello world');
    await tester.enterText(bioField, 'Changed text');
    await tester.pump();

    // Simulate iOS left-edge swipe back gesture: popGestureEnabled is false, so gesture must not pop route
    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(250, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    // Verify screen did NOT pop back to home page
    expect(find.text('Open Edit'), findsNothing);
    expect(find.text('編輯個人資料'), findsOneWidget);

    // Tapping the AppBar back button invokes confirmation dialog
    final backButton = find.byType(BackButton);
    expect(backButton, findsOneWidget);
    await tester.tap(backButton);
    await tester.pumpAndSettle();

    expect(find.text('捨棄未儲存的變更？'), findsOneWidget);
    expect(find.text('繼續編輯'), findsOneWidget);
  });

  testWidgets('EditProfileScreen blocks pop during saving (_loading == true)', (tester) async {
    final mockUser = AppUser(
      id: 'test-user-id',
      email: 'test@nycu.edu.tw',
      school: SCHOOL.NYCU,
      displayName: 'Alice',
      avatarUrl: 'test://avatar.png',
      department: '資工系',
      degreeLevel: DEGREE_LEVEL.UNDERGRAD,
      gender: 'FEMALE',
      bio: 'Hello world',
      contactIg: 'alice_ig',
      contactLine: null,
      contactDiscord: null,
      createdAt: DateTime(2026, 9, 1),
    );

    final completer = Completer<void>();
    final mockHttpClient = MockClient((request) async {
      await completer.future;
      return http.Response(
        jsonEncode(mockUser.toJson()),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
        request: request,
      );
    });

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('首頁')),
        ),
        GoRoute(
          path: '/edit',
          builder: (context, state) => const EditProfileScreen(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myAppUserProvider.overrideWith((ref) async => mockUser),
          supabaseClientProvider.overrideWithValue(
            SupabaseClient(
              'http://127.0.0.1:65535',
              'test-anon-key',
              httpClient: mockHttpClient,
              authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light,
          routerConfig: router,
        ),
      ),
    );

    router.push('/edit');
    await tester.pumpAndSettle();

    // Scroll until save button is visible and tap it
    final saveButton = find.text('儲存');
    await tester.scrollUntilVisible(saveButton, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(saveButton);
    await tester.pump(); // Enter _loading state while HTTP request is in-flight

    // PopScope must have canPop = false during loading
    final popScopeFinder = find.byWidgetPredicate((w) => w is PopScope);
    final loadingPopScope = tester.widget<PopScope>(popScopeFinder);
    expect(loadingPopScope.canPop, isFalse);

    // Attempt back navigation while loading
    await Navigator.maybePop(tester.element(popScopeFinder));
    await tester.pump();

    // Discard dialog should NOT be shown and screen must NOT pop
    expect(find.text('捨棄未儲存的變更？'), findsNothing);
    expect(find.text('編輯個人資料'), findsOneWidget);

    // Complete the pending request to avoid hanging timer/future
    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('WaitingRoomActionSections renders Column on narrow width to avoid overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: WaitingRoomActionSections(
                inviteToken: 'TEST-1234',
                busy: false,
                isOwner: true,
                onGenerate: () {},
                onCopy: () {},
                onManage: () {},
                onShare: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('複製邀請碼'), findsOneWidget);
    expect(find.text('複製邀請訊息'), findsOneWidget);

    final copyButton = tester.getRect(find.widgetWithText(OutlinedButton, '複製邀請碼'));
    final shareButton = tester.getRect(find.widgetWithText(FilledButton, '複製邀請訊息'));

    // Vertically stacked in a Column
    expect(copyButton.bottom, lessThanOrEqualTo(shareButton.top));
  });

  testWidgets('WaitingRoomActionSections renders Row on wide width with standard font', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 450,
              child: WaitingRoomActionSections(
                inviteToken: 'TEST-1234',
                busy: false,
                isOwner: true,
                onGenerate: () {},
                onCopy: () {},
                onManage: () {},
                onShare: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final copyButton = tester.getRect(find.widgetWithText(OutlinedButton, '複製邀請碼'));
    final shareButton = tester.getRect(find.widgetWithText(FilledButton, '複製邀請訊息'));

    // Horizontally laid out side-by-side in a Row
    expect(copyButton.right, lessThanOrEqualTo(shareButton.left));
  });
}
