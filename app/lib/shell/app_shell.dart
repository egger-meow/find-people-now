import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../activities/my_activities_providers.dart';
import '../downgrade/downgrade_consent_dialog.dart';
import '../notifications/notification_providers.dart';
import '../onboarding/onboarding_overlay.dart';
import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';
import '../widgets/app_glass_surface.dart';

/// 底部導覽（4 個主 tab）。`StatefulShellRoute.indexedStack`
/// 讓每個分支保留自己的 Navigator 堆疊跟捲動位置（切 tab 不會重置正在看的
/// 畫面），這是 go_router 官方推薦的底部導覽做法。
///
/// iOS 採浮動玻璃膠囊導覽列（iOS UX 指南 §8），
/// Android 採 Material 3 [NavigationBar]。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadNotificationCountProvider);
    final mediaQuery = MediaQuery.of(context);
    final isKeyboardOpen = mediaQuery.viewInsets.bottom > 0;

    void onDestinationSelected(int index) {
      AppHaptics.selection();
      if (index == 1) {
        invalidateMyActivityList(ref);
      }
      navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      );
    }

    // iOS 膠囊：圖示與常駐文字標籤共 64 + 內距 12 + 底部間距 8。
    const floatingBarHeight = 84.0;
    final effectivePadding = isCupertino && !isKeyboardOpen
        ? mediaQuery.padding.copyWith(
            bottom: mediaQuery.padding.bottom + floatingBarHeight,
          )
        : mediaQuery.padding;

    return OnboardingGate(
      child: DowngradeConsentGate(
        child: Scaffold(
          extendBody: isCupertino,
          body: MediaQuery(
            data: mediaQuery.copyWith(padding: effectivePadding),
            child: navigationShell,
          ),
          bottomNavigationBar: isCupertino
              ? (isKeyboardOpen
                    ? null
                    : _IosBottomNavigation(
                        currentIndex: navigationShell.currentIndex,
                        unreadCount: unreadCount,
                        onDestinationSelected: onDestinationSelected,
                      ))
              : NavigationBar(
                  selectedIndex: navigationShell.currentIndex,
                  onDestinationSelected: onDestinationSelected,
                  destinations: [
                    const NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore_rounded),
                      label: '探索',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.event_note_outlined),
                      selectedIcon: Icon(Icons.event_note_rounded),
                      label: '我的活動',
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
                        child: const Icon(Icons.notifications_outlined),
                      ),
                      selectedIcon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
                        child: const Icon(Icons.notifications_rounded),
                      ),
                      label: '通知',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '個人',
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _IosBottomNavigation extends StatelessWidget {
  const _IosBottomNavigation({
    required this.currentIndex,
    required this.unreadCount,
    required this.onDestinationSelected,
  });

  final int currentIndex;
  final int unreadCount;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const items = <(IconData, IconData, String)>[
      (CupertinoIcons.compass, CupertinoIcons.compass_fill, '探索'),
      (CupertinoIcons.calendar, CupertinoIcons.calendar_today, '我的活動'),
      (CupertinoIcons.bell, CupertinoIcons.bell_fill, '通知'),
      (CupertinoIcons.person, CupertinoIcons.person_fill, '個人'),
    ];

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: AppGlassSurface(
        padding: const EdgeInsets.all(6),
        borderRadius: BorderRadius.circular(AppRadius.glass),
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var index = 0; index < items.length; index++)
                Expanded(
                  child: Tooltip(
                    message: items[index].$3,
                    child: Semantics(
                      button: true,
                      selected: currentIndex == index,
                      label: items[index].$3,
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        onTap: () => onDestinationSelected(index),
                        child: AnimatedContainer(
                          duration: AppMotion.duration(
                            context,
                            AppMotion.normal,
                          ),
                          curve: AppMotion.curve,
                          decoration: BoxDecoration(
                            color: currentIndex == index
                                ? (isDark
                                      ? scheme.surfaceContainerHighest
                                            .withValues(alpha: 0.85)
                                      : scheme.primary.withValues(alpha: 0.14))
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: currentIndex == index
                                ? Border.all(
                                    color: isDark
                                        ? scheme.outlineVariant.withValues(
                                            alpha: 0.4,
                                          )
                                        : scheme.primary.withValues(
                                            alpha: 0.25,
                                          ),
                                    width: 1,
                                  )
                                : null,
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _CupertinoBadgeIcon(
                                  count: index == 2 ? unreadCount : 0,
                                  icon: Icon(
                                    currentIndex == index
                                        ? items[index].$2
                                        : items[index].$1,
                                    size: 24,
                                    color: currentIndex == index
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  index == 1 ? '活動' : items[index].$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    height: 1.1,
                                    color: currentIndex == index
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS 浮動玻璃導覽未讀徽章
class _CupertinoBadgeIcon extends StatelessWidget {
  const _CupertinoBadgeIcon({required this.count, required this.icon});

  final int count;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return icon;
    final text = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: -4,
          right: -8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: CupertinoColors.systemRed,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 14),
            child: Text(
              text,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}
