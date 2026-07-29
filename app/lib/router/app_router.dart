import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../activities/activity_detail_screen.dart';
import '../activities/my_activities_screen.dart';
import '../auth/auth_providers.dart';
import '../auth/complete_profile_screen.dart';
import '../auth/otp_login_screen.dart';
import '../match/create_request_screen.dart';
import '../match/match_providers.dart';
import '../match/waiting_room_screen.dart';
import '../notifications/notifications_screen.dart';
import '../onboarding/help_screen.dart';
import '../profile/edit_profile_screen.dart';
import '../profile/feedback_screen.dart';
import '../profile/profile_screen.dart';
import '../shell/app_shell.dart';

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

/// UI_PLAN.md §1 導覽結構——4-tab 底部導覽（[AppShell]）+ 底部導覽以外的
/// 全螢幕路由：
///   /login                — OTP 登入
///   /complete-profile       — 最小完善個人資料（create_request 的硬性前置）
///   /match                  — 配對頁填表（§2）／底部導覽「首頁」分支
///   /my-activities          — 我的活動（§4）／底部導覽「我的活動」分支
///   /notifications          — 通知（§5）／底部導覽「通知」分支
///   /profile                — 我的（§8.1）／底部導覽「我的」分支
///   /waiting-room/:id       — 等待室（§3），從「首頁」push 進來
///   /activity/:id           — 單一活動詳情（§4.1），從「我的活動」push 進來
///   /profile/edit           — 編輯個人資料
///   /profile/feedback       — 反饋/QA 靜態頁（§8.2）
///   /help                   — 常駐說明入口（§11.2）
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
      GoRoute(
        path: '/waiting-room/:requestId',
        builder: (context, state) => WaitingRoomScreen(
          requestId: state.pathParameters['requestId']!,
        ),
      ),
      GoRoute(
        path: '/activity/:activityId',
        builder: (context, state) => ActivityDetailScreen(
          activityId: state.pathParameters['activityId']!,
        ),
      ),
      GoRoute(path: '/profile/edit', builder: (context, state) => const EditProfileScreen()),
      GoRoute(path: '/profile/feedback', builder: (context, state) => const FeedbackScreen()),
      GoRoute(path: '/help', builder: (context, state) => const HelpScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/match', builder: (context, state) => const CreateRequestScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/my-activities', builder: (context, state) => const MyActivitiesScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/notifications', builder: (context, state) => const NotificationsScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen())],
          ),
        ],
      ),
    ],
  );
});
