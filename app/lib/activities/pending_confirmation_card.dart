import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL, PENDING_CONFIRMATION_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
import '../rpc/confirmation_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/countdown_text.dart';
import '../match/match_providers.dart' show myActiveActivityProvider, myActiveRequestProvider;
import '../widgets/loading_indicator.dart';
import 'my_activities_providers.dart';

String _degreeLabel(DEGREE_LEVEL level) => switch (level) {
      DEGREE_LEVEL.UNDERGRAD => '大學部',
      DEGREE_LEVEL.MASTER => '碩士班',
      DEGREE_LEVEL.PHD => '博士班',
    };

String _tierLabel(ReliabilityTier tier) => switch (tier) {
      ReliabilityTier.trusted => 'Trusted',
      ReliabilityTier.normal => 'Normal',
      ReliabilityTier.newUser => 'New',
      ReliabilityTier.unknown => '—',
    };

/// UI_PLAN.md §4 / §6.1 — `PENDING_CONFIRMATION` 卡片：SPEC §12.1.3「安全
/// 資訊卡」+「確認參加」/「這次先不要」動作。安全資訊卡的資料源
/// （`get_pending_confirmation_candidate_info`）是這輪新增的 RPC，見
/// SPEC.md v1.22 變更紀錄——之前完全沒有對應資料源。
class PendingConfirmationCard extends ConsumerStatefulWidget {
  const PendingConfirmationCard({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<PendingConfirmationCard> createState() => _PendingConfirmationCardState();
}

class _PendingConfirmationCardState extends ConsumerState<PendingConfirmationCard> {
  PendingConfirmationStatus? _status;
  PendingConfirmationCandidateInfo? _candidate;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = ref.read(supabaseClientProvider);
    try {
      final status = await getPendingConfirmationStatus(client, widget.requestId);
      PendingConfirmationCandidateInfo? candidate;
      // 對稱不歸因原則（SPEC §12.1.2）只保留在「誰確認/誰拒絕」這件事上——
      // 只要還在 PENDING，雙方都有權看到對方的安全資訊卡；狀態離開 PENDING
      // 之後不再需要，也不再顯示。
      if (status.status == PENDING_CONFIRMATION_STATUS.PENDING) {
        candidate = await getPendingConfirmationCandidateInfo(client, status.pendingConfirmationId);
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _candidate = candidate;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '載入失敗：${e.code.name}';
        _loading = false;
      });
    }
  }

  Future<void> _respond(bool confirm) async {
    final status = _status;
    if (status == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = ref.read(supabaseClientProvider);
    try {
      await respondPendingConfirmation(
        client,
        pendingConfirmationId: status.pendingConfirmationId,
        confirm: confirm,
      );
      if (!mounted) return;
      // 回應後整個「我的活動」清單都可能變（雙方皆確認 -> 這筆 Request 變成
      // Activity；拒絕 -> 這輪先重新載入這張卡片顯示「未成立」，狀態最終
      // 退回 REQUESTING 由背景任務處理，下次進頁面/下拉刷新會反映）。
      ref.invalidate(myActivityListProvider);
      ref.invalidate(myActiveRequestProvider);
      ref.invalidate(myActiveActivityProvider);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '回應失敗：${e.code.name}${e.detail != null ? '（${e.detail}）' : ''}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppCard(child: LoadingIndicator());
    }
    if (_error != null && _status == null) {
      return AppCard(child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)));
    }

    final status = _status!;
    if (status.status != PENDING_CONFIRMATION_STATUS.PENDING) {
      // SPEC §12.1.2 不歸因原則：不透露是誰、超時還是拒絕。
      return const AppCard(
        child: Text('此次配對未成立，別擔心，可以重新發起新的邀約。'),
      );
    }

    final candidate = _candidate!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('小人數安全確認', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(radius: 28, backgroundImage: NetworkImage(candidate.avatarUrl)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(candidate.displayName, style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      '${schoolLabel(candidate.school)} · ${candidate.department ?? '未填科系'} · ${_degreeLabel(candidate.degreeLevel)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '可信度 ${_tierLabel(candidate.reliabilityTier)} · 已完成 ${candidate.completedActivityCount} 次活動',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('確認時限'),
              CountdownText(
                deadline: status.confirmWindowExpireAt,
                style: Theme.of(context).textTheme.titleSmall,
                urgentColor: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final confirmDecline = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('這次先不要？'),
                              content: const Text(
                                '拒絕此候選配對後，系統將實施配對冷卻期（這段期間暫時無法發起新配對邀約）。\n\n'
                                '此操作屬於前置安全確認，不會記錄失信事件，也不會扣減您的信譽評分。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(false),
                                  child: const Text('再想想'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(context).pop(true),
                                  child: const Text('確定拒絕'),
                                ),
                              ],
                            ),
                          );
                          if (confirmDecline == true) {
                            _respond(false);
                          }
                        },
                  child: const Text('這次先不要'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(label: '確認參加', loading: _busy, onPressed: () => _respond(true)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
