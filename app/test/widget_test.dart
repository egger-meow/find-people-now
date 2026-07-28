// Boots the real app widget tree (go_router + AppTheme via the riverpod
// provider graph) against a real [SupabaseClient] pointed at the local
// Supabase instance (same no-mock convention as rpc_smoke_test.dart) and
// confirms an unauthenticated session lands on the OTP login screen — the
// go_router `redirect` in lib/router/app_router.dart is what's actually being
// exercised here, not a canned counter widget.
//
// Deliberately does NOT call `Supabase.initialize()` (the global singleton
// `supabase_bootstrap.dart` uses in real app startup): that path pulls in
// session-persistence storage plugins that hang forever under bare
// `flutter test` (no platform channel implementations registered outside
// `integration_test`). Overriding [supabaseClientProvider] with a plain
// [SupabaseClient] sidesteps that entirely while still exercising the real
// widget tree against a real backend.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/main.dart';

void main() {
  testWidgets('unauthenticated session lands on the OTP login screen', (WidgetTester tester) async {
    await dotenv.load();
    final client = SupabaseClient(
      dotenv.get('SUPABASE_URL'),
      dotenv.get('SUPABASE_ANON_KEY'),
      // No session is ever established in this test, so the periodic
      // auto-refresh timer would just sit there — `flutter_test` asserts no
      // timers are pending after a test finishes, so turn it off rather than
      // work around the assertion.
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [supabaseClientProvider.overrideWithValue(client)],
        child: const MyApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('學校信箱'), findsOneWidget);
    expect(find.text('傳送驗證碼'), findsOneWidget);
  });
}
