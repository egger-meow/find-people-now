import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/auth/complete_profile_screen.dart';
import 'package:find_people_now/auth/otp_login_screen.dart';
import 'package:find_people_now/theme/app_theme.dart';

SupabaseClient _createDummyClient() {
  return SupabaseClient(
    'https://mock.supabase.co',
    'mock-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

void main() {
  group('P2 UI/UX Audit Fixes - Auth & Profile (F01, F02, F03, F04)', () {
    testWidgets('F01: OtpLoginScreen displays persistent school domain helper text', (tester) async {
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

      expect(
        find.text('接受 @nycu.edu.tw 或 @nthu.edu.tw 學校信箱'),
        findsOneWidget,
      );
    });

    testWidgets('F02: OtpLoginScreen presents terms in continuous rich text without fragmented wrap', (tester) async {
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

      final richTextFinder = find.byWidgetPredicate((w) {
        if (w is RichText) {
          final plain = w.text.toPlainText();
          return plain.contains('繼續即表示你同意《服務條款》，並確認已閱讀《隱私權政策》。');
        }
        return false;
      });
      expect(richTextFinder, findsOneWidget);
    });

    testWidgets('F03 & F04: CompleteProfileScreen explicitly marks required fields and has contact selector', (tester) async {
      tester.view.physicalSize = const Size(800 * 2, 1400 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseClientProvider.overrideWithValue(_createDummyClient()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const CompleteProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check required indicators
      expect(find.text('(必填)'), findsWidgets);
      expect(find.text('大頭貼'), findsOneWidget);
      expect(find.text('顯示名稱 (必填)'), findsOneWidget);
      expect(find.text('自我介紹 (必填)'), findsOneWidget);
      expect(find.text('(必填，至少填寫一項)'), findsOneWidget);

      // Check contact type selector chips
      expect(find.text('Instagram'), findsOneWidget);
      expect(find.text('LINE'), findsOneWidget);
      expect(find.text('Discord'), findsOneWidget);

      // Check live missing items feedback
      expect(find.textContaining('完成註冊尚缺：'), findsOneWidget);
    });
  });
}
