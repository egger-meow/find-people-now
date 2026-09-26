import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../errors/user_error_message.dart';
import '../generated/supadart_header.dart'
    show DEGREE_LEVEL, PENDING_CONFIRMATION_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
import '../rpc/confirmation_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_section.dart';
import '../widgets/app_status_summary.dart';
import '../widgets/countdown_text.dart';
import '../match/match_providers.dart'
    show myActiveActivityProvider, myActiveRequestProvider;
import '../widgets/loading_indicator.dart';
import 'my_activities_providers.dart';

const pendingConfirmationMinimumActionExtent = 44.0;

abstract final class PendingConfirmationCopy {
  static const title = '等待你的安全確認';
  static const message = '請查看候選夥伴資訊，並在確認時限內決定是否參加。';
  static const confirm = '確認參加';
  static const reject = '這次先不要';
}

class PendingConfirmationActionGuard {
  bool _running = false;

  bool get isRunning => _running;

  Future<void> run(Future<void> Function() action) async {
    if (_running) return;
    _running = true;
    try {
      await action();
    } finally {
      _running = false;
    }
  }
}

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
  ConsumerState<PendingConfirmationCard> createState() =>
      _PendingConfirmationCardState();
}

class _PendingConfirmationCardState
    extends ConsumerState<PendingConfirmationCard> {
  PendingConfirmationStatus? _status;
  PendingConfirmationCandidateInfo? _candidate;
  bool _loading = true;
  bool _refreshing = false;
  bool _busy = false;
  bool _decisionDialogOpen = false;
  Timer? _refreshTimer;
  String? _error;
  final _responseGuard = PendingConfirmationActionGuard();

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted &&
          !_loading &&
          !_busy &&
          _status?.status == PENDING_CONFIRMATION_STATUS.PENDING) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final client = ref.read(supabaseClientProvider);
    try {
      final status = await getPendingConfirmationStatus(
        client,
        widget.requestId,
      );
      PendingConfirmationCandidateInfo? candidate = _candidate;
      // 對稱不歸因原則（SPEC §12.1.2）只保留在「誰確認/誰拒絕」這件事上——
      // 只要還在 PENDING，雙方都有權看到對方的安全資訊卡；狀態離開 PENDING
      // 之後不再需要，也不再顯示。
      if (status.status == PENDING_CONFIRMATION_STATUS.PENDING &&
          candidate == null) {
        candidate = await getPendingConfirmationCandidateInfo(
          client,
          status.pendingConfirmationId,
        );
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _candidate = candidate;
        _loading = false;
      });
      if (status.status == PENDING_CONFIRMATION_STATUS.CONFIRMED) {
        invalidateMyActivityList(ref);
        ref.invalidate(myActiveActivityProvider);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (silent) return;
      setState(() {
        _error = userErrorMessage(e);
        _loading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _respond(bool confirm) async {
    if (_busy) return;
    await _responseGuard.run(() async {
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
        invalidateMyActivityList(ref);
        ref.invalidate(myActiveRequestProvider);
        ref.invalidate(myActiveActivityProvider);
        await _load();
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() => _error = userErrorMessage(e));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  Future<void> _openConfirmedActivity() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    try {
      final row = await ref
          .read(supabaseClientProvider)
          .from('activity_member')
          .select('activity_id')
          .eq('source_request_id', widget.requestId)
          .eq('user_id', userId)
          .maybeSingle();
      if (!mounted) return;
      invalidateMyActivityList(ref);
      ref.invalidate(myActiveActivityProvider);
      final activityId = row?['activity_id'];
      if (activityId is String) {
        context.push('/activity/$activityId');
        return;
      }
    } catch (_) {
      if (!mounted) return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('活動正在同步，請稍後再試一次')));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppCard(child: LoadingIndicator());
    }
    if (_error != null && _status == null) {
      return AppCard(
        child: Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }

    final status = _status!;
    if (status.status == PENDING_CONFIRMATION_STATUS.CONFIRMED) {
      return AppStatusSummary(
        title: '配對已成立',
        message: '雙方已確認，活動已建立。請前往活動查看成員與集合資訊。',
        leading: Icon(
          Icons.check_circle_outline,
          color: Theme.of(context).colorScheme.primary,
        ),
        action: SizedBox(
          width: double.infinity,
          child: AppButton(label: '進入活動', onPressed: _openConfirmedActivity),
        ),
      );
    }
    if (status.status != PENDING_CONFIRMATION_STATUS.PENDING) {
      // SPEC §12.1.2 不歸因原則：不透露是誰、超時還是拒絕。
      return AppStatusSummary(
        title: '此次配對未成立',
        message: '此次配對未成立，別擔心，可以重新發起新的邀約。',
        leading: Icon(
          Icons.info_outline,
          color: Theme.of(context).colorScheme.primary,
        ),
        action: SizedBox(
          width: double.infinity,
          child: AppButton(label: '重新整理', onPressed: _loading ? null : _load),
        ),
      );
    }

    final candidate = _candidate!;
    return PendingConfirmationStatusView(
      status: status,
      candidate: candidate,
      busy: _busy || _decisionDialogOpen,
      error: _error,
      onConfirm: status.hasConfirmed ? () async {} : () => _respond(true),
      onReject: () async {
        if (_busy || _decisionDialogOpen) return;
        setState(() => _decisionDialogOpen = true);
        try {
          final confirmDecline = await showAppConfirmDialog(
            context,
            title: '這次先不要？',
            message:
                '拒絕此候選配對後，系統將實施配對冷卻期（這段期間暫時無法發起新配對邀約）。\n\n'
                '此操作屬於前置安全確認，不會記錄失信事件，也不會扣減您的信譽評分。',
            cancelLabel: '再想想',
            confirmLabel: '確定拒絕',
          );
          if (confirmDecline && mounted) {
            await _respond(false);
          }
        } finally {
          if (mounted) setState(() => _decisionDialogOpen = false);
        }
      },
    );
  }
}

/// The status-first, testable presentation for a pending safety confirmation.
/// RPC loading and invalidation stay in [PendingConfirmationCard].
class PendingConfirmationStatusView extends StatefulWidget {
  const PendingConfirmationStatusView({
    super.key,
    required this.status,
    required this.candidate,
    required this.busy,
    required this.onConfirm,
    required this.onReject,
    this.error,
  });

  final PendingConfirmationStatus status;
  final PendingConfirmationCandidateInfo candidate;
  final bool busy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;
  final String? error;

  @override
  State<PendingConfirmationStatusView> createState() =>
      _PendingConfirmationStatusViewState();
}

class _PendingConfirmationStatusViewState
    extends State<PendingConfirmationStatusView> {
  final _actionGuard = PendingConfirmationActionGuard();
  bool _locallyBusy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (widget.busy || _actionGuard.isRunning) return;
    setState(() => _locallyBusy = true);
    try {
      await _actionGuard.run(action);
    } finally {
      if (mounted) setState(() => _locallyBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final candidate = widget.candidate;
    final busy = widget.busy || _locallyBusy;
    final hasConfirmed = status.hasConfirmed;
    final deadline = status.confirmWindowExpireAt.toLocal();
    final deadlineLabel =
        '${deadline.month}/${deadline.day} '
        '${deadline.hour.toString().padLeft(2, '0')}:'
        '${deadline.minute.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppStatusSummary(
          title: hasConfirmed ? '已同意，等待對方確認' : PendingConfirmationCopy.title,
          message: hasConfirmed
              ? '你已確認參加。對方完成確認後，活動會出現在「我的活動」。'
              : PendingConfirmationCopy.message,
          leading: Icon(
            Icons.verified_user_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          deadline: '確認時限：$deadlineLabel',
          action: Row(
            children: [
              const Expanded(child: Text('剩餘時間')),
              CountdownText(
                deadline: status.confirmWindowExpireAt,
                style: Theme.of(context).textTheme.titleSmall,
                urgentColor: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppSection(
          title: '候選夥伴',
          description: '這些安全資訊協助你在不揭露確認進度的前提下做決定。',
          child: AppCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundImage: candidate.avatarUrl.isEmpty
                      ? null
                      : NetworkImage(candidate.avatarUrl),
                  child: candidate.avatarUrl.isEmpty
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
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
          ),
        ),
        if (widget.error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            widget.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        AppSection(
          title: '你的決定',
          description: '確認與拒絕是兩個獨立動作；送出期間會暫停按鈕，避免重複回應。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: double.infinity,
                height: pendingConfirmationMinimumActionExtent,
                child: AppButton(
                  label: hasConfirmed
                      ? '已確認參加'
                      : PendingConfirmationCopy.confirm,
                  loading: busy,
                  onPressed: busy || hasConfirmed
                      ? null
                      : () => _run(widget.onConfirm),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                height: pendingConfirmationMinimumActionExtent,
                child: OutlinedButton(
                  onPressed: busy ? null : () => _run(widget.onReject),
                  child: const Text(PendingConfirmationCopy.reject),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
