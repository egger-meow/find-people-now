import 'package:find_people_now/legal/legal_links.dart';
import 'package:find_people_now/auth/otp_login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legal links resolve to the existing documents', () {
    expect(
      LegalLinks.uri(LegalDocument.terms).toString(),
      contains('TERMS_OF_SERVICE.md'),
    );
    expect(
      LegalLinks.uri(LegalDocument.privacy).toString(),
      contains('PRIVACY_POLICY.md'),
    );
    expect(
      LegalLinks.uri(LegalDocument.accountDeletion).toString(),
      contains('PRIVACY_POLICY.md'),
    );
  });

  testWidgets('OTP login keeps both legal links beside its primary action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: OtpLoginScreen())),
    );
    expect(find.text('傳送驗證碼'), findsOneWidget);
    // F02: 法律文字採連續行內排版（Text.rich），消弭 Wrap 斷行碎裂與孤立標點，同時完整保留兩份條款連結
    expect(find.textContaining('《服務條款》'), findsOneWidget);
    expect(find.textContaining('《隱私權政策》'), findsOneWidget);
  });
}
