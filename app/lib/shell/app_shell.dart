import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../downgrade/downgrade_consent_dialog.dart';
import '../notifications/notification_providers.dart';
import '../onboarding/onboarding_overlay.dart';

/// UI_PLAN.md §1 — 底部導覽（4 個主 tab）。`StatefulShellRoute.indexedStack`
/// 讓每個分支保留自己的 Navigator 堆疊跟捲動位置（切 tab 不會重置正在看的
/// 畫面），這是 go_router 官方推薦的底部導覽做法，取代先前逐輪疊加的
/// 扁平路由清單（見 app_router.dart 舊版註解）。
///
/// [OnboardingGate]／[DowngradeConsentGate] 兩個「偵測到條件就跳全域彈窗」
/// 的 widget 掛在這一層、包住整個 shell——不管使用者登入後落在哪個 tab，
/// 都能觸發到；行為上跟哪個 tab 無關，不屬於任何單一分支的畫面邏輯。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    return OnboardingGate(
      child: DowngradeConsentGate(
        child: Scaffold(
          body: navigationShell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (index) =>
                navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore_rounded), label: '首頁'),
              const NavigationDestination(
                icon: Icon(Icons.event_note_outlined),
                selectedIcon: Icon(Icons.event_note_rounded),
                label: '活動',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text('$unreadCount'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text('$unreadCount'),
                  child: const Icon(Icons.notifications_rounded),
                ),
                label: '通知',
              ),
              const NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: '帳戶'),
            ],
          ),
        ),
      ),
    );
  }
}
