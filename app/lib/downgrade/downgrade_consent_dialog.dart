import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/downgrade_request.dart';
import '../generated/supadart_header.dart' show DOWNGRADE_RESPONSE;
import '../rpc/api_exception.dart';
import '../rpc/downgrade_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/countdown_text.dart';
import 'downgrade_providers.dart';

/// UI_PLAN.md §6.2 人數調整同意——掛在 shell 最外層（跟
/// [OnboardingGate](../onboarding/onboarding_overlay.dart) 同一層），偵測到
/// 「輪到我表態、還沒回應過」的 downgrade_request 就跳出彈窗，不用使用者自己
/// 跑去哪個畫面找。一次只顯示一個彈窗，用簡單佇列序列化，避免同時湊到多筆
/// pending downgrade 時彈窗疊彈窗。
class DowngradeConsentGate extends ConsumerStatefulWidget {
  const DowngradeConsentGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DowngradeConsentGate> createState() => _DowngradeConsentGateState();
}

class _DowngradeConsentGateState extends ConsumerState<DowngradeConsentGate> {
  final _handled = <String>{};
  final _queue = <DowngradeRequest>[];
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(pendingDowngradesStreamProvider, (previous, next) {
      final list = next.value;
      if (list == null) return;
      for (final dg in list) {
        if (_handled.contains(dg.id)) continue;
        _handled.add(dg.id);
        _maybeEnqueue(dg);
      }
    });
    return widget.child;
  }

  Future<void> _maybeEnqueue(DowngradeRequest dg) async {
    final response = await ref.read(myDowngradeResponseProvider(dg.id).future);
    if (!mounted) return;
    if (response != null && response != DOWNGRADE_RESPONSE.NO_RESPONSE) return;
    _queue.add(dg);
    _drain();
  }

  Future<void> _drain() async {
    if (_showing || _queue.isEmpty || !mounted) return;
    _showing = true;
    final dg = _queue.removeAt(0);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DowngradeConsentDialog(downgradeRequest: dg),
    );
    _showing = false;
    if (mounted) _drain();
  }
}

class _DowngradeConsentDialog extends ConsumerStatefulWidget {
  const _DowngradeConsentDialog({required this.downgradeRequest});

  final DowngradeRequest downgradeRequest;

  @override
  ConsumerState<_DowngradeConsentDialog> createState() => _DowngradeConsentDialogState();
}

class _DowngradeConsentDialogState extends ConsumerState<_DowngradeConsentDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _respond(bool agree) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await respondDowngrade(
        ref.read(supabaseClientProvider),
        downgradeRequestId: widget.downgradeRequest.id,
        agree: agree,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.consentWindowClosed || e.code == ApiErrorCode.alreadyResponded) {
        // 已經過期或已回應過（例如另一台裝置搶先按過）——直接關閉，不用讓
        // 使用者對著一個回應不了的彈窗卡住。
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = '回應失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dg = widget.downgradeRequest;
    return PopScope(
      canPop: false,
      child: AppAdaptiveDialog(
        title: '人數調整需要你同意',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('目前只湊到不夠原本門檻的人數，是否接受降到 ${dg.targetSize} 人成局？'),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('剩餘時間'),
                CountdownText(deadline: dg.expireAt, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
        actions: [
          AppDialogAction(label: '不同意', onPressed: _busy ? null : () => _respond(false)),
          AppDialogAction(label: '同意', isDefault: true, onPressed: _busy ? null : () => _respond(true)),
        ],
      ),
    );
  }
}
