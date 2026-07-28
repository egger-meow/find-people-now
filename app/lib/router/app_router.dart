import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../auth/complete_profile_screen.dart';
import '../auth/otp_login_screen.dart';
import '../match/create_request_screen.dart';
import '../match/match_providers.dart';
import '../match/waiting_room_screen.dart';

/// Bridges a [Stream] (here: `auth.onAuthStateChange`) into a [Listenable] so
/// go_router's `refreshListenable` re-evaluates `redirect` on every
/// sign-in/sign-out — this is what makes login/logout reroute immediately
/// with no manual `context.go(...)` call at the call site.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// UI_PLAN.md §1 導覽結構的最小切片（本輪只做配對頁＋等待室）：
///   /login              — OTP 登入（本輪新增的必要 gate）
///   /complete-profile    — 最小完善個人資料（同上，create_request 的硬性前置）
///   /match               — 配對頁填表（UI_PLAN §2）
///   /waiting-room/:id    — 等待室（UI_PLAN §3）
final goRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = GoRouterRefreshStream(
    ref.watch(supabaseClientProvider).auth.onAuthStateChange,
  );
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refreshNotifier,
    redirect: (context, state) async {
      final session = ref.read(supabaseClientProvider).auth.currentSession;
      final loggingIn = state.matchedLocation == '/login';

      if (session == null) {
        return loggingIn ? null : '/login';
      }

      final hasProfile = await ref.read(hasProfileProvider.future);
      final onProfileGate = state.matchedLocation == '/complete-profile';
      if (!hasProfile) {
        return onProfileGate ? null : '/complete-profile';
      }

      if (loggingIn || onProfileGate) {
        return '/match';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const OtpLoginScreen()),
      GoRoute(
        path: '/complete-profile',
        builder: (context, state) => const CompleteProfileScreen(),
      ),
      GoRoute(path: '/match', builder: (context, state) => const CreateRequestScreen()),
      GoRoute(
        path: '/waiting-room/:requestId',
        builder: (context, state) => WaitingRoomScreen(
          requestId: state.pathParameters['requestId']!,
        ),
      ),
    ],
  );
});
