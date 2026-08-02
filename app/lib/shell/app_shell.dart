import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../activities/my_activities_providers.dart';
import '../downgrade/downgrade_consent_dialog.dart';
import '../notifications/notification_providers.dart';
import '../onboarding/onboarding_overlay.dart';
import '../theme/platform_adaptive.dart';

/// UI_PLAN.md §1 — 底部導覽（4 個主 tab）。`StatefulShellRoute.indexedStack`
/// 讓每個分支保留自己的 Navigator 堆疊跟捲動位置（切 tab 不會重置正在看的
/// 畫面），這是 go_router 官方推薦的底部導覽做法，取代先前逐輪疊加的
/// 扁平路由清單（見 app_router.dart 舊版註解）。
///
/// [OnboardingGate]／[DowngradeConsentGate] 兩個「偵測到條件就跳全域彈窗」
/// 的 widget 掛在這一層、包住整個 shell——不管使用者登入後落在哪個 tab，
/// 都能觸發到；行為上跟哪個 tab 無關，不屬於任何單一分支的畫面邏輯。
///
/// 底部導覽本身依平台分岔（iOS 用 [CupertinoTabBar]／Android 用 Material
/// [NavigationBar]）——跟 Flutter 官方 platform-adaptations 導覽範例同一種
/// 分法，兩邊共用同一個 [navigationShell]，只有導覽列外觀不同，分支/路由
/// 行為完全一致。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    void onDestinationSelected(int index) {
      // 反饋：活動狀態可能在使用者離開「活動」分頁時，被背景排程（如
      // fn_complete_activities）在背後推進，myActivityListProvider 是快取的
      // FutureProvider、IndexedStack 又讓分頁常駐，不會自動重查——每次切回這個
      // 分頁時強制重新整理，確保「進行中」/「已結束」分類跟後端當下狀態一致。
      if (index == 1) {
        ref.invalidate(myActivityListProvider);
      }
      navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);
    }

    return OnboardingGate(
      child: DowngradeConsentGate(
        child: Scaffold(
          body: navigationShell,
          bottomNavigationBar: isCupertino
              ? CupertinoTabBar(
                  currentIndex: navigationShell.currentIndex,
                  onTap: onDestinationSelected,
                  items: [
                    const BottomNavigationBarItem(icon: Icon(CupertinoIcons.compass), activeIcon: Icon(CupertinoIcons.compass_fill), label: '首頁'),
                    const BottomNavigationBarItem(
                      icon: Icon(CupertinoIcons.calendar),
                      activeIcon: Icon(CupertinoIcons.calendar_today),
                      label: '活動',
                    ),
                    BottomNavigationBarItem(
                      icon: _CupertinoBadgeIcon(count: unreadCount, icon: const Icon(CupertinoIcons.bell)),
                      activeIcon: _CupertinoBadgeIcon(count: unreadCount, icon: const Icon(CupertinoIcons.bell_fill)),
                      label: '通知',
                    ),
                    const BottomNavigationBarItem(icon: Icon(CupertinoIcons.person), activeIcon: Icon(CupertinoIcons.person_fill), label: '帳戶'),
                  ],
                )
              : NavigationBar(
                  selectedIndex: navigationShell.currentIndex,
                  onDestinationSelected: onDestinationSelected,
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

/// [CupertinoTabBar] 的 [BottomNavigationBarItem] 沒有內建 badge 支援
/// （Material 那邊直接用 [Badge] 包 icon 就好），這裡用同樣的紅點+數字疊加
/// 手法自己刻一個，維持跟 Material 版一致的「有未讀才顯示」邏輯。
class _CupertinoBadgeIcon extends StatelessWidget {
  const _CupertinoBadgeIcon({required this.count, required this.icon});

  final int count;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: -4,
          right: -8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: CupertinoColors.systemRed, borderRadius: BorderRadius.circular(8)),
            constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
            child: Text(
              '$count',
              style: const TextStyle(color: CupertinoColors.white, fontSize: 10, height: 1.1),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}
