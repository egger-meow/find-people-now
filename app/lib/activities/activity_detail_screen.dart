import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart'
    show ACTIVITY_MEMBER_STATUS, ACTIVITY_STATUS, COMPLETION_RESULT, DEGREE_LEVEL, REPORT_CATEGORY;
import '../rpc/activity_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
import '../rpc/completion_rpc.dart';
import '../rpc/report_rpc.dart';
import '../rpc/user_block_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/loading_indicator.dart';
import 'activity_detail_providers.dart';

String _activityStatusLabel(ACTIVITY_STATUS status) => switch (status) {
      ACTIVITY_STATUS.MATCHED => '已成團，等待開始',
      ACTIVITY_STATUS.ONGOING => '進行中',
      ACTIVITY_STATUS.COMPLETED => '已完成',
      ACTIVITY_STATUS.CANCELLED => '已取消',
    };

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

String _reportCategoryLabel(REPORT_CATEGORY category) => switch (category) {
      REPORT_CATEGORY.SPAM => '騷擾廣告',
      REPORT_CATEGORY.HARASSMENT => '不當言行',
      REPORT_CATEGORY.OTHER => '其他',
    };

/// UI_PLAN.md §4.1 — 單一 `MATCHED`/`ONGOING` 活動自己的兩個分頁籤（地點／
/// 成員），從「我的活動」清單裡的一張卡片點進來，範圍只限於這一個活動實例，
/// 不是另一層跟 進行中/已結束 平行的頁面分頁。Round 2 做了「地點」；round 3
/// 補上「成員」（名單＋依 `source_request_id` 分組＋聯絡方式＋封鎖/檢舉）；
/// round 4 補上 UI_PLAN §6.3「完成確認＋再約」——`ONGOING` 時若本人還沒交過
/// `completion_report` 顯示回報banner，交完緊接跳出再約 sheet；`COMPLETED`
/// 之後不論當初有沒有交過回報，「成員」分頁籤都持續提供「👍 再約」按鈕（見
/// `_MemberCard` 的 `activityStatus` 參數），不綁死在送出 completion report
/// 那個當下才能按。
class ActivityDetailScreen extends ConsumerWidget {
  const ActivityDetailScreen({super.key, required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityAsync = ref.watch(activityStreamProvider(activityId));

    return Scaffold(
      appBar: AppBar(title: const Text('活動詳情')),
      body: SafeArea(
        child: activityAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('連線失敗：$error')),
          data: (activity) {
            if (activity == null) {
              return const Center(child: Text('找不到這個活動'));
            }
            return DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                    child: Text(_activityStatusLabel(activity.status), style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (activity.status == ACTIVITY_STATUS.ONGOING)
                    _CompletionReportBanner(activityId: activity.id),
                  const TabBar(tabs: [Tab(text: '地點'), Tab(text: '成員')]),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _LocationTab(activity: activity),
                        _MembersTab(activityId: activity.id, activityStatus: activity.status),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// UI_PLAN.md §6.3 第一步「完成確認」——只在活動 `ONGOING` 且本人還沒交過
/// `completion_report` 時顯示（RLS 限定只看得到自己交的那份，見
/// [ownCompletionReportProvider]）。文案呼應 `COMPLETE_CONFIRMATION`
/// 通知（docs/UI_PLAN.md §9）：「活動結束了嗎？花 10 秒回報一下」。
class _CompletionReportBanner extends ConsumerWidget {
  const _CompletionReportBanner({required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(ownCompletionReportProvider(activityId));
    return reportAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => const SizedBox.shrink(),
      data: (report) {
        if (report != null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
          child: AppCard(
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded),
                const SizedBox(width: AppSpacing.sm),
                const Expanded(child: Text('活動結束了嗎？花 10 秒回報一下')),
                FilledButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => _CompletionReportSheet(activityId: activityId),
                  ),
                  child: const Text('回報'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// UI_PLAN.md §6.3 三選一。選「對方沒來」時展開成員複選清單（限定
/// `JOINED` 成員，對齊 `submit_completion_report` 的 `INVALID_ABSENT_TARGET`
/// 檢查範圍）。任一選項送出成功後，緊接跳出第二步再約 sheet（同一節文案：
/// 「完成確認送出成功後緊接跳出」），對象是「本次回報中沒被我標記缺席的其他
/// 成員」——`SELF_CANCELLED` 也一併適用同一條規則，SPEC 沒有特別排除這個
/// 分支，維持三個結果分支統一行為，不特判。
class _CompletionReportSheet extends ConsumerStatefulWidget {
  const _CompletionReportSheet({required this.activityId});

  final String activityId;

  @override
  ConsumerState<_CompletionReportSheet> createState() => _CompletionReportSheetState();
}

class _CompletionReportSheetState extends ConsumerState<_CompletionReportSheet> {
  bool _pickingAbsent = false;
  final Set<String> _absentIds = {};
  bool _busy = false;
  String? _error;

  Future<void> _submit(COMPLETION_RESULT result, {List<String> absentUserIds = const []}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await submitCompletionReport(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        result: result,
        absentUserIds: absentUserIds,
      );
      ref.invalidate(ownCompletionReportProvider(widget.activityId));
      if (!mounted) return;
      Navigator.of(context).pop();

      final myId = ref.read(currentUserIdProvider);
      final roster = await ref.read(activityMemberRosterProvider(widget.activityId).future);
      final rematchTargets = roster
          .where((m) =>
              m.userId != myId &&
              m.status == ACTIVITY_MEMBER_STATUS.JOINED &&
              !absentUserIds.contains(m.userId))
          .toList();
      if (!mounted || rematchTargets.isEmpty) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _RematchSheet(activityId: widget.activityId, targets: rematchTargets),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == ApiErrorCode.alreadyReported ? '你已經回報過了' : '回報失敗：${e.code.name}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pickingAbsent) {
      return Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
        ),
        child: Consumer(
          builder: (context, ref, _) {
            final rosterAsync = ref.watch(activityMemberRosterProvider(widget.activityId));
            final myId = ref.watch(currentUserIdProvider);
            return rosterAsync.when(
              loading: () => const SizedBox(height: 120, child: LoadingIndicator()),
              error: (error, stack) => Text('載入失敗：$error'),
              data: (roster) {
                final candidates =
                    roster.where((m) => m.userId != myId && m.status == ACTIVITY_MEMBER_STATUS.JOINED).toList();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('誰沒有出現？', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    if (candidates.isEmpty) const Text('沒有其他成員可以指認'),
                    for (final m in candidates)
                      CheckboxListTile(
                        value: _absentIds.contains(m.userId),
                        title: Text(m.displayName),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            _absentIds.add(m.userId);
                          } else {
                            _absentIds.remove(m.userId);
                          }
                        }),
                      ),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    AppButton(
                      label: '送出',
                      loading: _busy,
                      onPressed: _absentIds.isEmpty
                          ? null
                          : () => _submit(COMPLETION_RESULT.REPORTED_ABSENT, absentUserIds: _absentIds.toList()),
                    ),
                  ],
                );
              },
            );
          },
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('這次活動順利進行嗎？', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: AppSpacing.xs),
          ],
          ListTile(
            leading: const Icon(Icons.check_circle_outline_rounded),
            title: const Text('✅ 順利進行'),
            onTap: _busy ? null : () => _submit(COMPLETION_RESULT.WENT_WELL),
          ),
          ListTile(
            leading: const Icon(Icons.cancel_outlined),
            title: const Text('❌ 對方沒來'),
            onTap: _busy ? null : () => setState(() => _pickingAbsent = true),
          ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline_rounded),
            title: const Text('⚪ 我自己取消了'),
            onTap: _busy ? null : () => _submit(COMPLETION_RESULT.SELF_CANCELLED),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: AppSpacing.sm), child: LoadingIndicator()),
        ],
      ),
    );
  }
}

/// UI_PLAN.md §6.3 第二步「再約」——完成確認送出成功後緊接跳出，只列出這次
/// 回報裡沒被標記缺席的其他成員（見呼叫端 `_CompletionReportSheet._submit`
/// 的過濾邏輯）。雙向才永久保留聯絡方式，單向判定完全交給 `rematch_vote`
/// RPC 的 `is_mutual` 回傳值，不在前端自己猜測對方是否已投（RLS 也擋著看不
/// 到，見 [ownRematchVotesProvider]）。
class _RematchSheet extends ConsumerStatefulWidget {
  const _RematchSheet({required this.activityId, required this.targets});

  final String activityId;
  final List<MemberRosterEntry> targets;

  @override
  ConsumerState<_RematchSheet> createState() => _RematchSheetState();
}

class _RematchSheetState extends ConsumerState<_RematchSheet> {
  final Set<String> _voted = {};
  final Set<String> _busy = {};

  Future<void> _vote(String toUserId) async {
    setState(() => _busy.add(toUserId));
    try {
      final result = await rematchVote(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        toUserId: toUserId,
      );
      ref.invalidate(ownRematchVotesProvider(widget.activityId));
      if (!mounted) return;
      setState(() => _voted.add(toUserId));
      if (result.isMutual) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('雙方都按了再約，永久保留聯絡方式囉！')));
      }
    } on ApiException {
      // 安靜失敗，使用者可再試一次——跟封鎖/檢舉一樣不特別解讀錯誤碼。
    } finally {
      if (mounted) setState(() => _busy.remove(toUserId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('要跟誰再約？', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text('雙方都按了才會永久保留聯絡方式', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          for (final m in widget.targets)
            ListTile(
              leading: CircleAvatar(
                backgroundImage: m.avatarUrl.isEmpty ? null : NetworkImage(m.avatarUrl),
                child: m.avatarUrl.isEmpty ? const Icon(Icons.person_rounded) : null,
              ),
              title: Text(m.displayName),
              trailing: OutlinedButton(
                onPressed: _voted.contains(m.userId) || _busy.contains(m.userId) ? null : () => _vote(m.userId),
                child: Text(_voted.contains(m.userId) ? '已按讚' : '👍 再約'),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '完成', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

class _LocationTab extends ConsumerWidget {
  const _LocationTab({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = activity.status == ACTIVITY_STATUS.MATCHED || activity.status == ACTIVITY_STATUS.ONGOING;
    return RefreshIndicator(
      onRefresh: () async =>
          ref.invalidate(approvedLocationsProvider((activity.school, activity.campus))),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text('活動地點', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          if (activity.activityLocationId != null)
            _LockedLocationCard(activity: activity)
          else
            _LocationVoting(activity: activity),
          const SizedBox(height: AppSpacing.lg),
          Text('集合地點', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          _MeetingPointSection(activityId: activity.id, editable: canEdit),
          const SizedBox(height: AppSpacing.lg),
          Text('見面提示（只有你看得到自己填的這份）', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          _MeetingHintSection(activityId: activity.id, editable: canEdit),
        ],
      ),
    );
  }
}

class _LockedLocationCard extends ConsumerWidget {
  const _LockedLocationCard({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locationsAsync = ref.watch(
      approvedLocationsProvider((activity.school, activity.campus)),
    );
    return AppCard(
      child: locationsAsync.when(
        loading: () => const LoadingIndicator(),
        error: (error, stack) => Text('載入失敗：$error'),
        data: (locations) {
          final locked = locations.where((l) => l.id == activity.activityLocationId).toList();
          final name = locked.isEmpty ? '（地點已鎖定）' : locked.first.name;
          return Row(
            children: [
              const Icon(Icons.lock_rounded, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(name, style: Theme.of(context).textTheme.titleSmall)),
            ],
          );
        },
      ),
    );
  }
}

class _LocationVoting extends ConsumerStatefulWidget {
  const _LocationVoting({required this.activity});

  final Activity activity;

  @override
  ConsumerState<_LocationVoting> createState() => _LocationVotingState();
}

class _LocationVotingState extends ConsumerState<_LocationVoting> {
  bool _busy = false;
  String? _error;

  Future<void> _vote(String locationId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await voteActivityLocation(
        ref.read(supabaseClientProvider),
        activityId: widget.activity.id,
        locationId: locationId,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '投票失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _propose(String locationId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await proposeActivityLocation(
        ref.read(supabaseClientProvider),
        activityId: widget.activity.id,
        locationId: locationId,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '提案失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProposeSheet(List<Location> allLocations, Set<String> proposedIds) async {
    final candidates = allLocations.where((l) => !proposedIds.contains(l.id)).toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        if (candidates.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text('這個校區的核准地點都已經是候選了'),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: [
            for (final loc in candidates)
              ListTile(title: Text(loc.name), onTap: () => Navigator.of(context).pop(loc.id)),
          ],
        );
      },
    );
    if (picked != null) await _propose(picked);
  }

  @override
  Widget build(BuildContext context) {
    final optionsAsync = ref.watch(activityLocationOptionsStreamProvider(widget.activity.id));
    final votesAsync = ref.watch(activityLocationVotesStreamProvider(widget.activity.id));
    final locationsAsync = ref.watch(
      approvedLocationsProvider((widget.activity.school, widget.activity.campus)),
    );
    final userId = ref.watch(currentUserIdProvider);

    if (optionsAsync.isLoading || votesAsync.isLoading || locationsAsync.isLoading) {
      return const AppCard(child: LoadingIndicator());
    }
    final optionsError = optionsAsync.hasError || votesAsync.hasError || locationsAsync.hasError;
    if (optionsError) {
      return const AppCard(child: Text('載入失敗'));
    }

    final options = optionsAsync.value ?? <ActivityLocationOption>[];
    final votes = votesAsync.value ?? [];
    final locations = {for (final l in locationsAsync.value ?? <Location>[]) l.id: l};
    final myVotes = votes.where((v) => v.userId == userId).toList();
    final myVoteLocationId = myVotes.isEmpty ? null : myVotes.first.locationId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (options.isEmpty)
          const AppCard(child: Text('還沒有人提案候選地點'))
        else
          for (final option in options) ...[
            AppCard(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      locations[option.locationId]?.name ?? '（地點）',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${votes.where((v) => v.locationId == option.locationId).length} 票',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: _busy || myVoteLocationId == option.locationId
                        ? null
                        : () => _vote(option.locationId),
                    child: Text(myVoteLocationId == option.locationId ? '已投' : '投給這裡'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: AppSpacing.xs),
        ],
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _openProposeSheet(
                    locationsAsync.value ?? [],
                    options.map((o) => o.locationId).toSet(),
                  ),
          icon: const Icon(Icons.add_location_alt_outlined),
          label: const Text('提案新地點'),
        ),
      ],
    );
  }
}

class _MeetingPointSection extends ConsumerStatefulWidget {
  const _MeetingPointSection({required this.activityId, this.editable = true});

  final String activityId;
  final bool editable;

  @override
  ConsumerState<_MeetingPointSection> createState() => _MeetingPointSectionState();
}

class _MeetingPointSectionState extends ConsumerState<_MeetingPointSection> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final description = _controller.text.trim();
    if (description.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await updateMeetingPoint(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        description: description,
      );
      if (!mounted) return;
      _controller.clear();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == ApiErrorCode.meetingPointUpdateCooldown
            ? '更新太頻繁，請稍後再試'
            : '更新失敗：${e.code.name}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updatesAsync = ref.watch(activityMeetingPointUpdatesStreamProvider(widget.activityId));

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          updatesAsync.when(
            loading: () => const LoadingIndicator(),
            error: (error, stack) => Text('載入失敗：$error'),
            data: (updates) => Text(
              updates.isEmpty ? '目前還沒有人設定集合地點' : updates.first.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (widget.editable) ...[
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: _controller, hint: '例如：正門警衛室旁'),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: AppSpacing.sm),
            AppButton(label: '更新集合地點', loading: _busy, onPressed: _submit),
          ],
        ],
      ),
    );
  }
}

class _MeetingHintSection extends ConsumerStatefulWidget {
  const _MeetingHintSection({required this.activityId, this.editable = true});

  final String activityId;
  final bool editable;

  @override
  ConsumerState<_MeetingHintSection> createState() => _MeetingHintSectionState();
}

class _MeetingHintSectionState extends ConsumerState<_MeetingHintSection> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(supabaseClientProvider);
    final userId = ref.read(currentUserIdProvider)!;
    final row = await client
        .from('activity_member')
        .select()
        .eq('activity_id', widget.activityId)
        .eq('user_id', userId)
        .maybeSingle();
    if (!mounted) return;
    setState(() {
      _controller.text = (row?['meeting_hint'] as String?) ?? '';
      _loading = false;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await updateMeetingHint(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        hint: _controller.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已更新見面提示')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '更新失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppCard(child: LoadingIndicator());
    }
    if (!widget.editable) {
      return AppCard(
        child: Text(
          _controller.text.isEmpty ? '（沒有填見面提示）' : _controller.text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(controller: _controller, hint: '例如：我會戴紅色棒球帽（限 30 字）'),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '更新見面提示', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}

/// UI_PLAN.md §4.1 Tab 2——成員名單依 `source_request_id` 分組顯示「一起
/// 來的」，每張卡片點開後顯示聯絡方式（依 `get_activity_contacts` 的
/// 24h/再約規則決定是否可見）＋封鎖／檢舉入口。
class _MembersTab extends ConsumerWidget {
  const _MembersTab({required this.activityId, required this.activityStatus});

  final String activityId;
  final ACTIVITY_STATUS activityStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rosterAsync = ref.watch(activityMemberRosterProvider(activityId));

    return rosterAsync.when(
      loading: () => const LoadingIndicator(),
      error: (error, stack) => Center(child: Text('載入失敗：$error')),
      data: (roster) {
        final groups = <String, List<MemberRosterEntry>>{};
        for (final member in roster) {
          groups.putIfAbsent(member.sourceRequestId, () => []).add(member);
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(activityMemberRosterProvider(activityId)),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              for (final group in groups.values) ...[
                if (group.length > 1) ...[
                  Text(
                    '一起加入',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                for (final member in group) ...[
                  _MemberCard(activityId: activityId, activityStatus: activityStatus, member: member),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

/// `activityStatus` 帶進來只為了 UI_PLAN §6.3「再約」按鈕：`COMPLETED` 之後
/// 才顯示，且不綁在「剛送出完成確認」那個當下——之後任何時間點回到這個活動
/// 都能繼續按（見 [_RematchButton]），呼應 UI_PLAN §4「COMPLETED」列的「再約
/// 按鈕」跟第一步/第二步彈窗（`_CompletionReportSheet`/`_RematchSheet`）是
/// 同一個底層 RPC 的兩個入口，不是兩套邏輯。
class _MemberCard extends ConsumerStatefulWidget {
  const _MemberCard({required this.activityId, required this.activityStatus, required this.member});

  final String activityId;
  final ACTIVITY_STATUS activityStatus;
  final MemberRosterEntry member;

  @override
  ConsumerState<_MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends ConsumerState<_MemberCard> {
  bool _expanded = false;

  Future<void> _confirmBlock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('封鎖這位成員？'),
        content: const Text('封鎖後，未來不會再被配對在一起。這個動作不會通知對方。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('封鎖')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await blockUser(ref.read(supabaseClientProvider), blockedId: widget.member.userId);
    } on ApiException {
      // 冪等 RPC，這輪不特別處理錯誤——安靜失敗，使用者可再試一次；不影響
      // 「成功後安靜關閉選單」這個非歸因設計（SPEC §12.1.2 精神的延伸）。
    }
    if (!mounted) return;
    setState(() => _expanded = false);
  }

  Future<void> _openReportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ReportSheet(reportedUserId: widget.member.userId),
    );
    if (!mounted) return;
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final userId = ref.watch(currentUserIdProvider);
    final isSelf = member.userId == userId;
    final isCancelled = member.status == ACTIVITY_MEMBER_STATUS.CANCELLED;

    return AppCard(
      onTap: isSelf ? null : () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundImage: member.avatarUrl.isEmpty ? null : NetworkImage(member.avatarUrl),
                child: member.avatarUrl.isEmpty ? const Icon(Icons.person_rounded) : null,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSelf ? '${member.displayName}（你）' : member.displayName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${schoolLabel(member.school)} · ${member.department ?? '未填科系'} · ${_degreeLabel(member.degreeLevel)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      isCancelled ? '已取消參加 · 可信度 ${_tierLabel(member.reliabilityTier)}' : '可信度 ${_tierLabel(member.reliabilityTier)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (!isSelf && widget.activityStatus == ACTIVITY_STATUS.COMPLETED && !isCancelled) ...[
                _RematchButton(activityId: widget.activityId, toUserId: member.userId),
                const SizedBox(width: AppSpacing.xs),
              ],
              if (!isSelf) Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            ],
          ),
          if (_expanded && !isSelf) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.sm),
            _MemberContactSection(contacts: member.contacts),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: _confirmBlock, child: const Text('封鎖')),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(onPressed: _openReportSheet, child: const Text('檢舉')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 卡片標題列上的常駐「👍 再約」按鈕，狀態來自 [ownRematchVotesProvider]
/// （RLS 只放行自己投出去的票，見該 provider 的說明）。跟展開/收合的手勢
/// 共用同一張 `AppCard`，但按鈕本身的 `OutlinedButton` 會吃掉自己的點擊，不
/// 會誤觸卡片的展開/收合。
class _RematchButton extends ConsumerStatefulWidget {
  const _RematchButton({required this.activityId, required this.toUserId});

  final String activityId;
  final String toUserId;

  @override
  ConsumerState<_RematchButton> createState() => _RematchButtonState();
}

class _RematchButtonState extends ConsumerState<_RematchButton> {
  bool _busy = false;

  Future<void> _vote() async {
    setState(() => _busy = true);
    try {
      final result = await rematchVote(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        toUserId: widget.toUserId,
      );
      ref.invalidate(ownRematchVotesProvider(widget.activityId));
      if (!mounted) return;
      if (result.isMutual) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('雙方都按了再約，永久保留聯絡方式囉！')));
      }
    } on ApiException {
      // 安靜失敗，使用者可再試一次。
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final votesAsync = ref.watch(ownRematchVotesProvider(widget.activityId));
    final voted = votesAsync.value?.contains(widget.toUserId) ?? false;
    return OutlinedButton(
      onPressed: voted || _busy ? null : _vote,
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
      child: Text(voted ? '已再約' : '👍 再約'),
    );
  }
}

class _MemberContactSection extends StatelessWidget {
  const _MemberContactSection({required this.contacts});

  final ActivityContactDetails? contacts;

  @override
  Widget build(BuildContext context) {
    if (contacts == null) {
      return Text(
        '聯絡方式尚未開放（配對成立 24 小時內，或雙方都按過「再約」才看得到）',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final lines = <String>[
      if (contacts!.contactIg != null) 'IG: ${contacts!.contactIg}',
      if (contacts!.contactLine != null) 'LINE: ${contacts!.contactLine}',
      if (contacts!.contactDiscord != null) 'Discord: ${contacts!.contactDiscord}',
    ];
    if (lines.isEmpty) {
      return Text('對方沒有留下聯絡方式', style: Theme.of(context).textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final line in lines) Text(line, style: Theme.of(context).textTheme.bodyMedium)],
    );
  }
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.reportedUserId});

  final String reportedUserId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  REPORT_CATEGORY _category = REPORT_CATEGORY.SPAM;
  final _detailController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _detailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = _detailController.text.trim();
      await submitReport(
        ref.read(supabaseClientProvider),
        category: _category,
        reportedUserId: widget.reportedUserId,
        detail: detail.isEmpty ? null : detail,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('檢舉這位成員', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<REPORT_CATEGORY>(
            initialValue: _category,
            items: [
              for (final category in REPORT_CATEGORY.values)
                DropdownMenuItem(value: category, child: Text(_reportCategoryLabel(category))),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _category = value);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(controller: _detailController, hint: '選填：補充說明'),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '送出檢舉', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}
