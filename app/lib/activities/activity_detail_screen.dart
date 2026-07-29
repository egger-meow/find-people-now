import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart'
    show ACTIVITY_MEMBER_STATUS, ACTIVITY_STATUS, DEGREE_LEVEL, REPORT_CATEGORY;
import '../rpc/activity_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
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
/// 補上「成員」（名單＋依 `source_request_id` 分組＋聯絡方式＋封鎖/檢舉）。
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
                  const TabBar(tabs: [Tab(text: '地點'), Tab(text: '成員')]),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _LocationTab(activity: activity),
                        _MembersTab(activityId: activity.id),
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

class _LocationTab extends ConsumerWidget {
  const _LocationTab({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
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
        _MeetingPointSection(activityId: activity.id),
        const SizedBox(height: AppSpacing.lg),
        Text('見面提示（只有你看得到自己填的這份）', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        _MeetingHintSection(activityId: activity.id),
      ],
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
  const _MeetingPointSection({required this.activityId});

  final String activityId;

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
          const SizedBox(height: AppSpacing.sm),
          AppTextField(controller: _controller, hint: '例如：正門警衛室旁'),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '更新集合地點', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}

class _MeetingHintSection extends ConsumerStatefulWidget {
  const _MeetingHintSection({required this.activityId});

  final String activityId;

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
  const _MembersTab({required this.activityId});

  final String activityId;

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
                  _MemberCard(member: member),
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

class _MemberCard extends ConsumerStatefulWidget {
  const _MemberCard({required this.member});

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
                      '${member.school.name} · ${member.department ?? '未填科系'} · ${_degreeLabel(member.degreeLevel)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      isCancelled ? '已取消參加 · 可信度 ${_tierLabel(member.reliabilityTier)}' : '可信度 ${_tierLabel(member.reliabilityTier)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
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
