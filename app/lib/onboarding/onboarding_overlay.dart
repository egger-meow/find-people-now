import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../match/match_providers.dart' show myAppUserProvider;
import '../theme/app_theme.dart';

/// UI_PLAN.md §11.1 — 首次登入跳出卡片，只在 `app_user.onboarding_seen_at`
/// 為 null 時自動觸發一次。存後端而非本機記憶（見該節理由：換手機/重灌 App
/// 是常見情境）。掛在 shell 最外層，包住整個底部導覽——這樣不管使用者第一次
/// 登入後落在哪個 tab，都能觸發到。
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shown) return;
      final user = ref.read(myAppUserProvider).value;
      if (user != null && user.onboardingSeenAt == null) {
        _shown = true;
        _showOnboarding();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(myAppUserProvider, (previous, next) {
      final user = next.value;
      if (!_shown && user != null && user.onboardingSeenAt == null) {
        _shown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showOnboarding();
        });
      }
    });
    return widget.child;
  }

  Future<void> _showOnboarding() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const _OnboardingDialog(),
    );
    if (!mounted) return;
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

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _cards.length - 1;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxDialogHeight = screenHeight * 0.82;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: maxDialogHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_page + 1} / ${_cards.length}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
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
                          vertical: AppSpacing.sm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              body,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    height: 1.5,
                                  ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _cards.length; i++)
                    AnimatedContainer(
                      duration: AppMotion.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _page ? 20 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: () {
                    if (isLast) {
                      Navigator.of(context).pop();
                    } else {
                      _controller.nextPage(
                        duration: AppMotion.normal,
                        curve: AppMotion.curve,
                      );
                    }
                  },
                  child: Text(isLast ? '開始使用' : '下一步'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
