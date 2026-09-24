import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
