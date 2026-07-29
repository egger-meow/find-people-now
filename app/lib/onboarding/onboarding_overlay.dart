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
      barrierDismissible: false,
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
  ('選活動、約時間', '選活動類型、時段、人數 → 送出，進入「等待室」'),
  ('邀朋友，或讓系統配對', '等待室可以邀朋友一起，也可以直接等系統幫你配對陌生人'),
  ('配對成功', '配對成功（人數少時會先跳出安全確認）→ 進「我的活動」'),
  ('約碰面細節', '活動確定後：一起投票決定去哪、填集合地點、填見面提示，方便認出彼此'),
  ('活動結束', '花 10 秒回報有沒有順利進行，可以跟一起參加的人按「再約」'),
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
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '跳過',
                ),
              ],
            ),
            SizedBox(
              height: 180,
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final (title, body) in _cards)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.sm),
                          Text(body, style: Theme.of(context).textTheme.bodyMedium),
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
                onPressed: () {
                  if (isLast) {
                    Navigator.of(context).pop();
                  } else {
                    _controller.nextPage(duration: AppMotion.normal, curve: AppMotion.curve);
                  }
                },
                child: Text(isLast ? '開始使用' : '下一步'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
