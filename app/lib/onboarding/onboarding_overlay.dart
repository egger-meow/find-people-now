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
/// 「開始探索」按鈕。只介紹眼前第一步，不在首次開啟時灌入完整流程。
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
          .update({
            'onboarding_seen_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
    } catch (_) {
      // 安靜失敗——最壞情況只是下次登入又跳一次，不影響使用流程本身。
    }
    ref.invalidate(myAppUserProvider);
  }
}

class _OnboardingFloatingCard extends StatelessWidget {
  const _OnboardingFloatingCard({required this.onDismiss});

  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Dismissible(
      key: const ValueKey('onboarding_floating_card'),
      direction: DismissDirection.up,
      onDismissed: (_) => onDismiss(),
      child: Material(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
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
                  Text('第一次使用？', style: theme.textTheme.labelMedium),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: onDismiss,
                    tooltip: '跳過',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.xs,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '先找想做的事',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '從探索頁選活動與時間；需要揪人時再發起需求。後續操作會在對應畫面出現。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(88, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                  ),
                  onPressed: onDismiss,
                  child: const Text('開始探索'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
