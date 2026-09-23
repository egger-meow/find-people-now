import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../match/match_providers.dart' show myAppUserProvider;
import '../theme/app_theme.dart';

/// UI_PLAN.md §11.1 & iOS 優先指南：
/// 首次登入非阻斷式引導小卡，僅在 `app_user.onboarding_seen_at` 為 null 時
/// 浮現在安全區頂部。存後端而非本機記憶。
///
/// 關鍵架構：非模態（Non-blocking）、無 ModalBarrier。
/// 以 Stack 疊在 AppShell 最外層，完全不遮擋與阻斷底部導覽（BottomNavigationBar）
/// 與懸浮按鈕（FAB）。支援向上滑動關閉（DismissDirection.up）、右上角關閉或
/// 「開始使用」按鈕。
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(myAppUserProvider).value;
    final shouldShow =
        !_dismissed && user != null && user.onboardingSeenAt == null;

    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    // 約束卡片最高為畫面高度的 48%，確保中心與底部完全暴露且可直接點選
    final cardMaxHeight = (screenHeight * 0.48).clamp(180.0, 320.0);

    return Stack(
      children: [
        widget.child,
        if (shouldShow)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 440,
                      maxHeight: cardMaxHeight,
                    ),
                    child: _OnboardingFloatingCard(
                      onDismiss: _dismissOnboarding,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _dismissOnboarding() async {
    setState(() => _dismissed = true);
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final client = ref.read(supabaseClientProvider);
    try {
      await client
          .from('app_user')
          .update({'onboarding_seen_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', userId);
    } catch (_) {
      // 安靜失敗——最壞情況只是下次登入又跳一次，不影響使用流程本身。
    }
    ref.invalidate(myAppUserProvider);
  }
}

const _cards = [
  ('選活動與時間', '選活動類型、時段與人數 → 送出後進入等待室，系統會持續比對相容夥伴。'),
  ('等配對，也能邀朋友', '在等待室可以直接等系統配對，也可以一鍵複製邀請碼或分享給朋友，加入後立即同房。'),
  ('成團後約地點、報到', '配對成功後：投票決定集合地點；現場點「我到了」完成報到，結束後花十秒回報並可選再約。'),
];

class _OnboardingFloatingCard extends StatefulWidget {
  const _OnboardingFloatingCard({required this.onDismiss});

  final Future<void> Function() onDismiss;

  @override
  State<_OnboardingFloatingCard> createState() =>
      _OnboardingFloatingCardState();
}

class _OnboardingFloatingCardState extends State<_OnboardingFloatingCard> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLast = _page == _cards.length - 1;

    return Dismissible(
      key: const ValueKey('onboarding_floating_card'),
      direction: DismissDirection.up,
      onDismissed: (_) => widget.onDismiss(),
      child: Material(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      '${_page + 1} / ${_cards.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: widget.onDismiss,
                    tooltip: '跳過',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                  ),
                ],
              ),
              Flexible(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    for (final (title, body) in _cards)
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                          vertical: AppSpacing.xs,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              body,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.4,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  for (var i = 0; i < _cards.length; i++)
                    AnimatedContainer(
                      duration: AppMotion.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: i == _page ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? scheme.primary
                            : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(88, 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                    ),
                    onPressed: () {
                      if (isLast) {
                        widget.onDismiss();
                      } else {
                        _controller.nextPage(
                          duration: AppMotion.normal,
                          curve: AppMotion.curve,
                        );
                      }
                    },
                    child: Text(isLast ? '開始使用' : '下一步'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
