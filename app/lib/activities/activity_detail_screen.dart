import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../data/skill_level_labels.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart'
    show ACTIVITY_MEMBER_STATUS, ACTIVITY_STATUS, COMPLETION_RESULT, DEGREE_LEVEL, RELIABILITY_EVENT_TYPE, REPORT_CATEGORY;
import '../match/match_providers.dart' show activityTypesProvider, myActiveActivityProvider, myAppUserProvider;
import '../rpc/activity_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
import '../rpc/completion_rpc.dart';
import '../rpc/location_rpc.dart';
import '../rpc/report_rpc.dart';
import '../rpc/user_block_rpc.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_text_field.dart';
import '../widgets/loading_indicator.dart';
import 'activity_detail_providers.dart';
import 'my_activities_providers.dart';

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

/// Vibe Tags（v1.28）——依活動類型關鍵字給一組情境標籤選項，同
/// `data/activity_type_icons.dart` 的 `activityTypeIcon` 一樣純展示、不接後端
/// 審核表（見 `update_vibe_tags` 遷移檔頭註解的取捨說明）。比對不到就給一組
/// 泛用預設，不因為新類型沒錄入就沒有標籤可選。
List<String> _vibeTagOptionsFor(String activityTypeName) {
  final n = activityTypeName.toLowerCase();
  const sporty = ['新手歡樂場', '認真拼戰', '流汗就好'];
  const table = <String, List<String>>{
    '籃球': sporty,
    '排球': sporty,
    '羽球': sporty,
    '網球': sporty,
    '桌球': sporty,
    '足球': sporty,
    '棒球': sporty,
    '健身': sporty,
    '重訓': sporty,
    '慢跑': sporty,
    '跑步': sporty,
    '游泳': sporty,
    '讀書': ['靜音專注', '刷題討論', '互相監督'],
    '唸書': ['靜音專注', '刷題討論', '互相監督'],
    '自習': ['靜音專注', '刷題討論', '互相監督'],
    '咖啡': ['隨意閒聊', '社恐友善', '純吃美食'],
    '吃飯': ['隨意閒聊', '社恐友善', '純吃美食'],
    '晚餐': ['隨意閒聊', '社恐友善', '純吃美食'],
    '午餐': ['隨意閒聊', '社恐友善', '純吃美食'],
  };
  for (final entry in table.entries) {
    if (n.contains(entry.key)) return entry.value;
  }
  return const ['新手歡樂場', '認真投入', '隨興就好'];
}

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

  Future<void> _showCancelDialog(BuildContext context, WidgetRef ref, Activity activity) async {
    final now = DateTime.now();
    final isEarlyCancel = activity.startTime.difference(now).inMinutes >= 60;

    final confirmed = await showAppConfirmDialog(
      context,
      title: isEarlyCancel ? '確定要退出活動？' : '⚠️ 確定要退出活動？',
      message: isEarlyCancel
          ? '距離活動開始還有 1 小時以上。\n\n'
              '取消參加屬於正常行程變更（Early Cancel），不會觸發配對冷卻期，也不會扣減您的信譽評分。'
          : '距離活動開始已不足 1 小時（或活動進行中）。\n\n'
              '⚠️ 退出將被記錄為 Late Cancel，並觸發配對冷卻期（期間無法發起新配對），同時會影響您的信譽評分與可信度等級。',
      cancelLabel: '返回',
      confirmLabel: '確定退出',
      isDestructive: !isEarlyCancel,
    );

    if (!confirmed || !context.mounted) return;

    try {
      final client = ref.read(supabaseClientProvider);
      final result = await cancelActivityParticipation(client, activity.id);
      if (!context.mounted) return;

      invalidateMyActivityList(ref);
      ref.invalidate(myActiveActivityProvider);
      ref.invalidate(myAppUserProvider);

      final msg = result.eventType == RELIABILITY_EVENT_TYPE.EARLY_CANCEL
          ? '已退出活動（Early Cancel，無冷卻）'
          : '已退出活動（Late Cancel，已觸發配對冷卻期）';

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('退出活動失敗：${e.code.name}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 反饋：活動狀態（如 ONGOING → COMPLETED）由背景排程觸發，不是使用者操作，
    // 「我的活動」清單的 myActivityListProvider 只是快取的 FutureProvider，不會自動
    // 感知這種變化——沒有這個 listen，使用者留在詳情頁看到最新狀態，回到清單卻還卡在
    // 舊分頁（見 project_stale_futureprovider_gating 這類 bug）。
    ref.listen<AsyncValue<Activity?>>(activityStreamProvider(activityId), (previous, next) {
      final prevStatus = previous?.value?.status;
      final nextStatus = next.value?.status;
      if (nextStatus != null && nextStatus != prevStatus) {
        invalidateMyActivityList(ref);
        ref.invalidate(myActiveActivityProvider);
      }
    });

    final activityAsync = ref.watch(activityStreamProvider(activityId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('活動詳情'),
        actions: [
          activityAsync.maybeWhen(
            data: (activity) {
              if (activity == null) return const SizedBox.shrink();
              if (activity.status == ACTIVITY_STATUS.MATCHED || activity.status == ACTIVITY_STATUS.ONGOING) {
                return PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'cancel') {
                      _showCancelDialog(context, ref, activity);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'cancel',
                      child: Row(
                        children: [
                          Icon(Icons.exit_to_app_rounded, color: Colors.red),
                          SizedBox(width: AppSpacing.sm),
                          Text('退出活動', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: SafeArea(
        child: activityAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('連線失敗：$error')),
          data: (activity) {
            if (activity == null) {
              return const Center(child: Text('找不到這個活動'));
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                  child: Text(_activityStatusLabel(activity.status), style: Theme.of(context).textTheme.titleMedium),
                ),
                if (activity.status == ACTIVITY_STATUS.ONGOING) _CompletionReportBanner(activityId: activity.id),
                Expanded(child: _ActivityDetailTabs(activity: activity)),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 「地點／成員」分頁依平台分岔：Android 用 Material `TabBar`+`TabBarView`；
/// iOS 用 [CupertinoSlidingSegmentedControl] 驅動一個普通 `int` 索引 +
/// [IndexedStack]——理由跟 [MyActivitiesScreen] 頂層分頁一樣（Cupertino
/// 沒有對應 `TabBarView` 的手勢滑動元件）。底下兩個分頁內容
/// （[_LocationTab]／[_MembersTab]）完全不變。
class _ActivityDetailTabs extends StatefulWidget {
  const _ActivityDetailTabs({required this.activity});

  final Activity activity;

  @override
  State<_ActivityDetailTabs> createState() => _ActivityDetailTabsState();
}

class _ActivityDetailTabsState extends State<_ActivityDetailTabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final locationTab = _LocationTab(activity: activity);
    final membersTab = _MembersTab(
      activityId: activity.id,
      activityStatus: activity.status,
      activityTypeId: activity.activityTypeId,
    );

    if (isCupertino) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: _index,
              children: const {0: Text('地點'), 1: Text('成員')},
              onValueChanged: (value) {
                if (value != null) setState(() => _index = value);
              },
            ),
          ),
          Expanded(child: IndexedStack(index: _index, children: [locationTab, membersTab])),
        ],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: '地點'), Tab(text: '成員')]),
          Expanded(child: TabBarView(children: [locationTab, membersTab])),
        ],
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
                const Expanded(
                  child: Text('活動結束了嗎？花 10 秒回報一下', maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(64, 36),
                  ),
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
              key: ValueKey(m.userId),
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 40,
                height: 40,
                child: CircleAvatar(
                  backgroundImage: m.avatarUrl.isEmpty ? null : NetworkImage(m.avatarUrl),
                  child: m.avatarUrl.isEmpty ? const Icon(Icons.person_rounded) : null,
                ),
              ),
              title: Text(m.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(64, 36),
                ),
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
          // 反饋：「見面提示只有自己看得到自己填的這份，什麼意思，那個不是給
          // 別人看的嗎」——原本的文案講反了。RLS 上 activity_member 對同一活動
          // 全體成員互相可見（my_activity_members_select），這裡填的提示就是
          // 給對方認出你用的（見 SPEC.md §9.2「穿紅色外套，帶著筆電」的例子），
          // 只是「編輯欄位」本身當然只能編輯自己那一則。
          Text('見面提示（讓對方認出你，同組成員都看得到）', style: Theme.of(context).textTheme.titleSmall),
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
    // v1.30：activity.activityLocationId 現在指向 activity_location_option.id
    // （可能是既有 location 候選，也可能是自訂候選），不再直接指向 location(id)，
    // 所以要先從候選清單找出得票勝出的那筆，再視它是哪種來源解析顯示名稱。
    final optionsAsync = ref.watch(activityLocationOptionsStreamProvider(activity.id));
    final locationsAsync = ref.watch(
      approvedLocationsProvider((activity.school, activity.campus)),
    );
    return AppCard(
      child: optionsAsync.when(
        loading: () => const LoadingIndicator(),
        error: (error, stack) => Text('載入失敗：$error'),
        data: (options) {
          final locked = options.where((o) => o.id == activity.activityLocationId).toList();
          String name = '（地點已鎖定）';
          if (locked.isNotEmpty) {
            final option = locked.first;
            if (option.customName != null) {
              name = option.customName!;
            } else {
              final locations = locationsAsync.value ?? const <Location>[];
              final matching = locations.where((l) => l.id == option.locationId);
              name = matching.isEmpty ? '（地點已鎖定）' : matching.first.name;
            }
          }
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

  Future<void> _vote(String optionId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await voteActivityLocation(
        ref.read(supabaseClientProvider),
        activityId: widget.activity.id,
        optionId: optionId,
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

  /// 反饋：「投票地點的候選改不用審核，使用者可以自己打字新增投票選項」——
  /// 活動類型已擴充到桌遊、麻將、校外咖啡廳等只會用這一次的地點，硬要求先送
  /// admin 審核、永久寫進全域清單既不合理也造成清單污染。這裡直接建立僅該活動
  /// 可見的候選（不經審核，不落地 location 表），成功後其他成員立刻能看到、
  /// 直接投給它（同 activityLocationOptionsStreamProvider 的既有 Realtime 疊加）。
  Future<void> _proposeCustom() async {
    final nameController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAdaptiveDialog(
        title: '新增這場活動的候選地點',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '例如校外咖啡廳、桌遊店——不用審核，馬上就能投票，但只有這場活動看得到',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: nameController, label: '地點名稱', autofocus: true, maxLength: 40),
          ],
        ),
        actions: [
          AppDialogAction(label: '取消', onPressed: () => Navigator.of(dialogContext).pop(false)),
          AppDialogAction(label: '新增並投票', isDefault: true, onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await proposeActivityLocation(
        ref.read(supabaseClientProvider),
        activityId: widget.activity.id,
        customName: name,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '新增失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 跟 [_proposeCustom] 不同：那邊是只給這場活動用的一次性候選，這裡是
  /// 「這個地點以後其他活動應該也用得到」時，送一筆全新的申請給 admin 審核、
  /// 加入官方地點清單（見 `propose_location` 的既有審核機制）。
  Future<void> _proposeNewLocation() async {
    final nameController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAdaptiveDialog(
        title: '建議加入官方地點清單',
        content: AppTextField(controller: nameController, label: '地點名稱', autofocus: true),
        actions: [
          AppDialogAction(label: '取消', onPressed: () => Navigator.of(dialogContext).pop(false)),
          AppDialogAction(label: '送出', isDefault: true, onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final client = ref.read(supabaseClientProvider);
    try {
      await proposeLocation(client, name: name, school: widget.activity.school, campus: widget.activity.campus);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已送出「$name」，審核通過後才能投給這裡（這場活動想馬上投票，改用「新增這場活動的候選地點」）')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.duplicateLocationName ? '這個地點已經存在了' : '送出失敗：${e.code.name}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    final myVoteOptionId = myVotes.isEmpty ? null : myVotes.first.optionId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (options.isEmpty)
          const AppCard(child: Text('還沒有人提案候選地點'))
        else
          for (final option in options) ...[
            AppCard(
              key: ValueKey(option.id),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      option.customName ?? locations[option.locationId]?.name ?? '（地點）',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${votes.where((v) => v.optionId == option.id).length} 票',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(64, 36)),
                    onPressed: _busy || myVoteOptionId == option.id ? null : () => _vote(option.id),
                    child: Text(myVoteOptionId == option.id ? '已投' : '投給這裡'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        const SizedBox(height: AppSpacing.sm),
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: AppSpacing.xs),
        ],
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _openProposeSheet(
                    locationsAsync.value ?? [],
                    options.where((o) => o.locationId != null).map((o) => o.locationId!).toSet(),
                  ),
          icon: const Icon(Icons.add_location_alt_outlined),
          label: const Text('提案新地點'),
        ),
        const SizedBox(height: AppSpacing.xs),
        OutlinedButton.icon(
          onPressed: _busy ? null : _proposeCustom,
          icon: const Icon(Icons.edit_location_alt_outlined),
          label: const Text('新增這場活動的候選地點'),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          onPressed: _busy ? null : _proposeNewLocation,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('這個地點以後也會用到？建議加入官方清單'),
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
            AppTextField(controller: _controller, hint: '例如：正門警衛室旁', maxLength: 40),
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
          AppTextField(controller: _controller, hint: '例如：我會戴紅色棒球帽', maxLength: 30),
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
  const _MembersTab({required this.activityId, required this.activityStatus, required this.activityTypeId});

  final String activityId;
  final ACTIVITY_STATUS activityStatus;
  final String activityTypeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rosterAsync = ref.watch(activityMemberRosterProvider(activityId));
    final arrivalOverride = ref.watch(activityArrivalStreamProvider(activityId)).value;
    final vibeTagsOverride = ref.watch(activityVibeTagsStreamProvider(activityId)).value;
    final showArrival = activityStatus == ACTIVITY_STATUS.MATCHED || activityStatus == ACTIVITY_STATUS.ONGOING;
    final typesAsync = ref.watch(activityTypesProvider);
    final matchingTypes = typesAsync.value?.where((t) => t.id == activityTypeId) ?? const Iterable.empty();
    final activityTypeName = matchingTypes.isEmpty ? '' : matchingTypes.first.name;

    return rosterAsync.when(
      loading: () => const LoadingIndicator(),
      error: (error, stack) => Center(child: Text('載入失敗：$error')),
      data: (rawRoster) {
        final roster = [
          for (final member in rawRoster)
            () {
              var m = member;
              if (arrivalOverride != null && arrivalOverride.containsKey(m.userId)) {
                m = m.copyWithArrivedAt(arrivalOverride[m.userId]);
              }
              if (vibeTagsOverride != null && vibeTagsOverride.containsKey(m.userId)) {
                m = m.copyWithVibeTags(vibeTagsOverride[m.userId]!);
              }
              return m;
            }(),
        ];
        final groups = <String, List<MemberRosterEntry>>{};
        for (final member in roster) {
          groups.putIfAbsent(member.sourceRequestId, () => []).add(member);
        }
        final joinedCount = roster.where((m) => m.status == ACTIVITY_MEMBER_STATUS.JOINED).length;
        final arrivedCount = roster
            .where((m) => m.status == ACTIVITY_MEMBER_STATUS.JOINED && m.arrivedAt != null)
            .length;
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(activityMemberRosterProvider(activityId)),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (showArrival && joinedCount > 0) ...[
                AppCard(
                  child: Row(
                    children: [
                      Icon(Icons.flag_circle_rounded, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text('已抵達 $arrivedCount / $joinedCount', style: Theme.of(context).textTheme.titleSmall),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
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
                  _MemberCard(
                    key: ValueKey(member.userId),
                    activityId: activityId,
                    activityStatus: activityStatus,
                    member: member,
                    activityTypeName: activityTypeName,
                  ),
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
  const _MemberCard({
    super.key,
    required this.activityId,
    required this.activityStatus,
    required this.member,
    required this.activityTypeName,
  });

  final String activityId;
  final ACTIVITY_STATUS activityStatus;
  final MemberRosterEntry member;
  final String activityTypeName;

  @override
  ConsumerState<_MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends ConsumerState<_MemberCard> {
  bool _expanded = false;

  Future<void> _confirmBlock() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '封鎖這位成員？',
      message: '封鎖後，未來不會再被配對在一起。這個動作不會通知對方。',
      confirmLabel: '封鎖',
      isDestructive: true,
    );
    if (!confirmed) return;
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

  Future<void> _editVibeTags() async {
    final options = _vibeTagOptionsFor(widget.activityTypeName);
    // 反饋：tag 也可以用來溝通（例如籃球「#有帶球」讓其他人知道不用帶），
    // 所以除了預設選項，使用者要能自己打字新增——後端 update_vibe_tags 本來
    // 就沒有白名單限制（只驗證數量 ≤3、單則 ≤20 字，見遷移檔註解），這裡補上
    // 前端缺的自由輸入欄位即可，不算新開放什麼。
    final selected = <String>[...widget.member.vibeTags];
    final textController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void addCustomTag(String raw) {
            final tag = raw.trim();
            if (tag.isEmpty || tag.length > 20) return;
            if (selected.contains(tag) || selected.length >= 3) return;
            setDialogState(() {
              selected.add(tag);
              textController.clear();
            });
          }

          return AppAdaptiveDialog(
            title: '這場你想怎麼參與？',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '最多 3 個，可以自己打字（例如 #有帶球），讓其他人即時看到',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final option in options)
                      FilterChip(
                        label: Text(option),
                        selected: selected.contains(option),
                        onSelected: (value) => setDialogState(() {
                          if (value) {
                            if (selected.length < 3) selected.add(option);
                          } else {
                            selected.remove(option);
                          }
                        }),
                      ),
                    for (final tag in selected.where((t) => !options.contains(t)))
                      InputChip(
                        label: Text(tag),
                        onDeleted: () => setDialogState(() => selected.remove(tag)),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: textController,
                  maxLength: 20,
                  enabled: selected.length < 3,
                  decoration: InputDecoration(
                    hintText: selected.length >= 3 ? '最多 3 個標籤' : '輸入自訂標籤',
                    isDense: true,
                    counterText: '',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add_rounded),
                      tooltip: '新增標籤',
                      onPressed: selected.length >= 3 ? null : () => addCustomTag(textController.text),
                    ),
                  ),
                  onSubmitted: addCustomTag,
                ),
              ],
            ),
            actions: [
              AppDialogAction(label: '取消', onPressed: () => Navigator.of(dialogContext).pop(false)),
              AppDialogAction(label: '儲存', isDefault: true, onPressed: () => Navigator.of(dialogContext).pop(true)),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await updateVibeTags(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        tags: selected,
      );
      ref.invalidate(activityMemberRosterProvider(widget.activityId));
    } on ApiException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('儲存失敗，請再試一次')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final userId = ref.watch(currentUserIdProvider);
    final isSelf = member.userId == userId;
    final isCancelled = member.status == ACTIVITY_MEMBER_STATUS.CANCELLED;
    final showArrival = widget.activityStatus == ACTIVITY_STATUS.MATCHED || widget.activityStatus == ACTIVITY_STATUS.ONGOING;

    return AppCard(
      onTap: isSelf ? null : () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // v1.33 個人檔案卡：頭像本身有自己獨立的 tap target，跟外層
              // AppCard 展開聯絡方式的 onTap 分開——同一顆卡片上
              // _RematchButton/_ArrivalButton 也是各自獨立的按鈕、不會誤觸卡片
              // 的展開/收合，這裡採用同樣的巢狀手勢寫法。只有非本人才能點開
              // （自己的檔案卡意義不大，且原本 isSelf 時整張卡的 onTap 就是
              // null）。
              InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: isSelf
                    ? null
                    : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (context) => _ProfileCardSheet(member: member),
                        ),
                child: CircleAvatar(
                  radius: 22,
                  backgroundImage: member.avatarUrl.isEmpty ? null : NetworkImage(member.avatarUrl),
                  child: member.avatarUrl.isEmpty ? const Icon(Icons.person_rounded) : null,
                ),
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
                    // v1.34/v1.35 — 該成員發起/加入配對當下指定的程度／讀書目標，
                    // 兩者互斥（分屬不同活動類型），非 null 才顯示。
                    if (member.skillLevel != null)
                      Text(
                        '程度：${skillLevelLabel(member.skillLevel!)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (member.studyTarget != null && member.studyTarget!.isNotEmpty)
                      Text(
                        '讀書目標：${member.studyTarget}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (showArrival && !isCancelled) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            member.arrivedAt != null ? Icons.check_circle_rounded : Icons.schedule_rounded,
                            size: 14,
                            color: member.arrivedAt != null
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            member.arrivedAt != null ? '已抵達' : '尚未抵達',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: member.arrivedAt != null
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ],
                    if (member.vibeTags.isNotEmpty || (isSelf && !isCancelled)) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final tag in member.vibeTags)
                            Chip(
                              label: Text(tag, style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: EdgeInsets.zero,
                            ),
                          if (isSelf && !isCancelled)
                            ActionChip(
                              avatar: const Icon(Icons.add_rounded, size: 14),
                              label: Text(member.vibeTags.isEmpty ? '設定參與方式' : '編輯', style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              onPressed: _editVibeTags,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (!isSelf && widget.activityStatus == ACTIVITY_STATUS.COMPLETED && !isCancelled) ...[
                _RematchButton(activityId: widget.activityId, toUserId: member.userId),
                const SizedBox(width: AppSpacing.xs),
              ],
              if (isSelf && showArrival && !isCancelled && member.arrivedAt == null)
                _ArrivalButton(activityId: widget.activityId),
              if (!isSelf) Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            ],
          ),
          if (_expanded && !isSelf) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.sm),
            if (member.meetingHint?.isNotEmpty == true) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.face_retouching_natural_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(member.meetingHint!, style: Theme.of(context).textTheme.bodyMedium)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
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

/// 個人檔案卡（v1.33）——點成員頭像開啟，唯讀展示照片＋自我介紹＋科系等。
/// 版面參照 `profile_screen.dart` 的 `_ProfileHeaderCard`/`_MoreInfoSection`
/// （大頭貼＋姓名＋學校/科系/學制 header，展開式自我介紹區塊），但這裡是看
/// 別人、沒有編輯按鈕，且自我介紹一律直接展開顯示，不需要收合互動。
/// `bio` 從 v1.33 起是註冊硬性門檻（見 SPEC.md v1.33），新使用者一定填過；
/// 既有使用者若還沒補，走 fallback 文案，不是錯誤狀態。
class _ProfileCardSheet extends StatelessWidget {
  const _ProfileCardSheet({required this.member});

  final MemberRosterEntry member;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
          Center(
            child: CircleAvatar(
              radius: 40,
              backgroundImage: member.avatarUrl.isEmpty ? null : NetworkImage(member.avatarUrl),
              child: member.avatarUrl.isEmpty ? const Icon(Icons.person_rounded, size: 40) : null,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Text(
              member.displayName,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '${schoolLabel(member.school)} · ${member.department ?? '未填科系'} · ${_degreeLabel(member.degreeLevel)}',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: Text(
              '可信度 ${_tierLabel(member.reliabilityTier)}',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (member.skillLevel != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                '程度：${skillLevelLabel(member.skillLevel!)}',
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
          if (member.studyTarget != null && member.studyTarget!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                '讀書目標：${member.studyTarget}',
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Text('自我介紹', style: textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.xs),
          Text(
            member.bio.isNotEmpty ? member.bio : '還沒有寫自我介紹',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
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
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(64, 36),
      ),
      child: Text(voted ? '已再約' : '👍 再約'),
    );
  }
}

/// Arrival Check「我到了」按鈕（API.md §6.8）。只出現在自己的卡片上、還沒
/// 標記抵達時；按下後靠 [activityArrivalStreamProvider] 的 Realtime 推播
/// 自然更新畫面，這裡不用手動 invalidate 或本地樂觀更新。
class _ArrivalButton extends ConsumerStatefulWidget {
  const _ArrivalButton({required this.activityId});

  final String activityId;

  @override
  ConsumerState<_ArrivalButton> createState() => _ArrivalButtonState();
}

class _ArrivalButtonState extends ConsumerState<_ArrivalButton> {
  bool _busy = false;

  Future<void> _markArrived() async {
    setState(() => _busy = true);
    try {
      await markArrived(ref.read(supabaseClientProvider), activityId: widget.activityId);
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('標記失敗，請再試一次')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _busy ? null : _markArrived,
      style: FilledButton.styleFrom(
        minimumSize: const Size(112, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      ),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.near_me_rounded, size: 18),
      label: Text(_busy ? '標記中…' : '我到了', style: const TextStyle(fontWeight: FontWeight.w700)),
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
    final lines = <(String label, String value)>[
      if (contacts!.contactIg != null) ('IG', contacts!.contactIg!),
      if (contacts!.contactLine != null) ('LINE', contacts!.contactLine!),
      if (contacts!.contactDiscord != null) ('Discord', contacts!.contactDiscord!),
    ];
    if (lines.isEmpty) {
      return Text('對方沒有留下聯絡方式', style: Theme.of(context).textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (label, value) in lines) _ContactLine(label: label, value: value)],
    );
  }
}

/// 反饋：「看別人聯絡方式，要可以一鍵複製比較方便」。
class _ContactLine extends StatelessWidget {
  const _ContactLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text('$label: $value', style: Theme.of(context).textTheme.bodyMedium),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: '複製',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已複製 $label')));
            },
          ),
        ],
      ),
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
