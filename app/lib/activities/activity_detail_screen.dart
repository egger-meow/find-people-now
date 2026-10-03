import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../data/sport_level_config.dart';
import '../errors/user_error_message.dart';
import '../generated/activity.dart';
import '../generated/activity_location_option.dart';
import '../generated/activity_location_vote.dart';
import '../generated/activity_meeting_point_update.dart';
import '../generated/completion_report.dart';
import '../generated/location.dart';
import '../generated/supadart_header.dart'
    show
        ACTIVITY_MEMBER_STATUS,
        ACTIVITY_STATUS,
        COMPLETION_RESULT,
        DEGREE_LEVEL,
        RELIABILITY_EVENT_TYPE,
        REPORT_CATEGORY;
import '../match/match_providers.dart'
    show activityTypesProvider, myActiveActivityProvider, myAppUserProvider;
import '../rpc/activity_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart'
    show ReliabilityTier, ReliabilityTierExtension;
import '../rpc/completion_rpc.dart';
import '../rpc/location_rpc.dart';
import '../rpc/report_rpc.dart';
import '../rpc/user_block_rpc.dart';
import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';
import '../widgets/adaptive_refresh.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_error_state.dart';
import '../widgets/app_glass_surface.dart';
import '../widgets/app_section.dart';
import '../widgets/app_sheet.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_status_summary.dart';
import '../widgets/app_sticky_action_area.dart';
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

String _hm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _activityTimeLabel(Activity activity) {
  final start = activity.startTime.toLocal();
  final end = activity.estimatedEndTime.toLocal();
  return '${start.month.toString().padLeft(2, '0')}/${start.day.toString().padLeft(2, '0')} '
      '${_hm(start)}–${_hm(end)}';
}

String _nextActionDescription(
  ACTIVITY_STATUS status, {
  required bool hasLocationOptions,
  required bool locationLoading,
  required bool locationError,
}) => switch (status) {
  ACTIVITY_STATUS.MATCHED when locationLoading => '下一步：正在確認地點投票',
  ACTIVITY_STATUS.MATCHED when locationError => '下一步：地點載入失敗，請再試一次',
  ACTIVITY_STATUS.MATCHED => hasLocationOptions ? '下一步：投票選出集合地點' : '下一步：提出候選地點',
  ACTIVITY_STATUS.ONGOING when locationLoading => '下一步：正在確認集合地點',
  ACTIVITY_STATUS.ONGOING when locationError => '下一步：地點載入失敗，請再試一次',
  ACTIVITY_STATUS.ONGOING => hasLocationOptions ? '下一步：確認報到狀態' : '下一步：先提出候選地點',
  ACTIVITY_STATUS.COMPLETED => '下一步：查看成員並選擇再約',
  ACTIVITY_STATUS.CANCELLED => '下一步：查看活動紀錄',
};

String _stickyActionLabel(
  ACTIVITY_STATUS status, {
  required bool hasLocationOptions,
  required bool locationLoading,
  required bool locationError,
  int sectionIndex = 0,
}) {
  if (status == ACTIVITY_STATUS.MATCHED || status == ACTIVITY_STATUS.ONGOING) {
    if (locationLoading) return '正在載入地點資訊';
    if (locationError) return '重新載入地點資訊';
    if (sectionIndex == 1) {
      return hasLocationOptions ? '返回地點頁參與投票' : '返回地點頁提出候選';
    }
    return hasLocationOptions ? '查看成員與聯絡' : '提出地點';
  }
  if (status == ACTIVITY_STATUS.COMPLETED) {
    return sectionIndex == 1 ? '返回活動紀錄' : '查看成員與再約';
  }
  if (status == ACTIVITY_STATUS.CANCELLED) {
    return '查看活動紀錄';
  }
  return '查看成員與聯絡';
}

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
class ActivityDetailScreen extends ConsumerStatefulWidget {
  const ActivityDetailScreen({super.key, required this.activityId});

  final String activityId;

  @override
  ConsumerState<ActivityDetailScreen> createState() =>
      _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends ConsumerState<ActivityDetailScreen> {
  final _votingKey = GlobalKey<_LocationVotingState>();
  int _sectionIndex = 0;
  bool _leaving = false;

  Future<void> _showCancelDialog(Activity activity) async {
    if (_leaving) return;
    setState(() => _leaving = true);
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

    if (!mounted) return;
    if (!confirmed) {
      setState(() => _leaving = false);
      return;
    }
    try {
      final client = ref.read(supabaseClientProvider);
      final result = await cancelActivityParticipation(client, activity.id);
      if (!mounted) return;

      invalidateMyActivityList(ref);
      ref.invalidate(myActiveActivityProvider);
      ref.invalidate(myAppUserProvider);

      final msg = result.eventType == RELIABILITY_EVENT_TYPE.EARLY_CANCEL
          ? '已退出活動（Early Cancel，無冷卻）'
          : '已退出活動（Late Cancel，已觸發配對冷卻期）';

      showAppSnackBar(context, msg);
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, userErrorMessage(e), kind: AppSnackKind.error);
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _handleStickyMarkArrived(String activityId) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '確定你已經到了嗎？',
      message: '按下後會立刻通知其他成員你已抵達，無法收回。',
      confirmLabel: '我到了',
    );
    if (!confirmed) return;
    try {
      await markArrived(
        ref.read(supabaseClientProvider),
        activityId: activityId,
      );
      AppHaptics.success();
      if (mounted) {
        showAppSnackBar(
          context,
          '已完成報到！已通知其他成員你已抵達。',
          kind: AppSnackKind.success,
        );
      }
    } on ApiException {
      if (mounted) {
        showAppSnackBar(context, '標記失敗，請再試一次', kind: AppSnackKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 反饋：活動狀態（如 ONGOING → COMPLETED）由背景排程觸發，不是使用者操作，
    // 「我的活動」清單的 myActivityListProvider 只是快取的 FutureProvider，不會自動
    // 感知這種變化——沒有這個 listen，使用者留在詳情頁看到最新狀態，回到清單卻還卡在
    // 舊分頁（見 project_stale_futureprovider_gating 這類 bug）。
    ref.listen<AsyncValue<Activity?>>(
      activityStreamProvider(widget.activityId),
      (previous, next) {
        final prevStatus = previous?.value?.status;
        final nextStatus = next.value?.status;
        if (nextStatus != null && nextStatus != prevStatus) {
          invalidateMyActivityList(ref);
          ref.invalidate(myActiveActivityProvider);
        }
      },
    );

    final activityAsync = ref.watch(activityStreamProvider(widget.activityId));

    return Scaffold(
      // AppStickyActionArea already consumes viewInsets to keep the primary
      // action above the keyboard. Letting Scaffold resize the body as well
      // would apply the same keyboard inset twice.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('活動詳情')),
      body: SafeArea(
        child: activityAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => const AppErrorState(),
          data: (activity) {
            if (activity == null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.event_busy_rounded,
                        size: 44,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        '找不到這個活動，可能已經結束或已取消',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton(
                        label: '返回我的活動',
                        onPressed: () => context.go('/my-activities'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final locationOptionsAsync = ref.watch(
              activityLocationOptionsStreamProvider(activity.id),
            );
            final locationVotesAsync = ref.watch(
              activityLocationVotesStreamProvider(activity.id),
            );
            final approvedLocationsAsync = ref.watch(
              approvedLocationsProvider((activity.school, activity.campus)),
            );
            final hasLocationOptions =
                activity.activityLocationId != null ||
                (locationOptionsAsync.value?.isNotEmpty ?? false);
            final locationLoading =
                locationOptionsAsync.isLoading ||
                locationVotesAsync.isLoading ||
                approvedLocationsAsync.isLoading;
            final locationError =
                locationOptionsAsync.hasError ||
                locationVotesAsync.hasError ||
                approvedLocationsAsync.hasError;
            final currentUserId = ref.watch(currentUserIdProvider);
            final rosterAsync = ref.watch(
              activityMemberRosterProvider(activity.id),
            );
            final arrivalOverride = ref
                .watch(activityArrivalStreamProvider(activity.id))
                .value;
            final myMember = rosterAsync.value
                ?.where((m) => m.userId == currentUserId)
                .firstOrNull;
            final hasMyArrived =
                (arrivalOverride != null &&
                    currentUserId != null &&
                    arrivalOverride.containsKey(currentUserId))
                ? arrivalOverride[currentUserId] != null
                : myMember?.arrivedAt != null;
            final isMyJoined =
                myMember?.status == ACTIVITY_MEMBER_STATUS.JOINED;
            final canMarkArrived =
                activity.status == ACTIVITY_STATUS.ONGOING &&
                isMyJoined &&
                !hasMyArrived;

            return ActivityDetailBodyLayout(
              summary: ActivityDetailStatusSummary(
                activity: activity,
                canMarkArrived: canMarkArrived,
              ),
              completionBanner:
                  (activity.status == ACTIVITY_STATUS.ONGOING ||
                      activity.status == ACTIVITY_STATUS.COMPLETED)
                  ? _CompletionReportBanner(
                      activityId: activity.id,
                      activityStatus: activity.status,
                      contactVisibleUntil: activity.contactVisibleUntil,
                      startTime: activity.startTime,
                    )
                  : null,
              navigation: ActivityDetailNavigation(
                index: _sectionIndex,
                onChanged: (value) => setState(() => _sectionIndex = value),
              ),
              content: IndexedStack(
                index: _sectionIndex,
                children: [
                  _LocationTab(
                    key: const Key('location-tab'),
                    votingKey: _votingKey,
                    activity: activity,
                    leaving: _leaving,
                    onLeave:
                        activity.status == ACTIVITY_STATUS.MATCHED ||
                            activity.status == ACTIVITY_STATUS.ONGOING
                        ? () => _showCancelDialog(activity)
                        : null,
                  ),
                  MembersTab(
                    activityId: activity.id,
                    activityStatus: activity.status,
                    activityTypeId: activity.activityTypeId,
                  ),
                ],
              ),
              stickyAction: ActivityDetailStickyAction(
                status: activity.status,
                hasLocationOptions: hasLocationOptions,
                locationLoading: locationLoading,
                locationError: locationError,
                sectionIndex: _sectionIndex,
                customLabel: canMarkArrived ? '我到了' : null,
                customIcon: canMarkArrived ? Icons.near_me_rounded : null,
                onPressed: canMarkArrived
                    ? () => _handleStickyMarkArrived(activity.id)
                    : () {
                        final locationNeedsReload =
                            (activity.status == ACTIVITY_STATUS.MATCHED ||
                                activity.status == ACTIVITY_STATUS.ONGOING) &&
                            locationError;
                        if (locationNeedsReload) {
                          setState(() => _sectionIndex = 0);
                          ref.invalidate(
                            activityLocationOptionsStreamProvider(activity.id),
                          );
                          ref.invalidate(
                            activityLocationVotesStreamProvider(activity.id),
                          );
                          ref.invalidate(
                            approvedLocationsProvider((
                              activity.school,
                              activity.campus,
                            )),
                          );
                          return;
                        }

                        if (_sectionIndex == 1) {
                          setState(() => _sectionIndex = 0);
                          ref.invalidate(
                            activityLocationOptionsStreamProvider(activity.id),
                          );
                          ref.invalidate(
                            activityLocationVotesStreamProvider(activity.id),
                          );
                          ref.invalidate(
                            approvedLocationsProvider((
                              activity.school,
                              activity.campus,
                            )),
                          );
                        } else {
                          if (!hasLocationOptions) {
                            _votingKey.currentState?.triggerProposeSheet();
                          } else {
                            setState(() => _sectionIndex = 1);
                            ref.invalidate(
                              activityMemberRosterProvider(activity.id),
                            );
                          }
                        }
                      },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Status-first activity layout shared with visual regression tests. Without
/// the keyboard, the complete summary and navigation take their intrinsic
/// height before tab content. Under keyboard pressure only, the header gets a
/// bounded scroll viewport so both navigation and editable content retain a
/// usable target.
class ActivityDetailBodyLayout extends StatelessWidget {
  const ActivityDetailBodyLayout({
    super.key,
    required this.summary,
    this.completionBanner,
    required this.navigation,
    required this.content,
    required this.stickyAction,
  });

  final Widget summary;
  final Widget? completionBanner;
  final Widget navigation;
  final Widget content;
  final Widget stickyAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = theme.scaffoldBackgroundColor;

    return Column(
      children: [
        Expanded(
          child: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.xs,
                      AppSpacing.lg,
                      AppSpacing.xs,
                    ),
                    child: AppGlassSurface(
                      padding: EdgeInsets.zero,
                      child: summary,
                    ),
                  ),
                ),
                if (completionBanner != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        bottom: AppSpacing.sm,
                      ),
                      child: completionBanner!,
                    ),
                  ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _ActivityDetailNavigationSliverDelegate(
                    navigation: navigation,
                    backgroundColor: bgColor,
                  ),
                ),
              ];
            },
            body: content,
          ),
        ),
        stickyAction,
      ],
    );
  }
}

class _ActivityDetailNavigationSliverDelegate
    extends SliverPersistentHeaderDelegate {
  _ActivityDetailNavigationSliverDelegate({
    required this.navigation,
    required this.backgroundColor,
  });

  final Widget navigation;
  final Color backgroundColor;

  @override
  double get minExtent => 52.0;
  @override
  double get maxExtent => 52.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      alignment: Alignment.center,
      child: navigation,
    );
  }

  @override
  bool shouldRebuild(_ActivityDetailNavigationSliverDelegate oldDelegate) {
    return oldDelegate.navigation != navigation ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}


class ActivityDetailNavigation extends StatelessWidget {
  const ActivityDetailNavigation({
    super.key,
    required this.index,
    required this.onChanged,
  });

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (isCupertino) {
      return ConstrainedBox(
        key: const Key('activity-detail-navigation'),
        constraints: const BoxConstraints(minHeight: 46),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: index,
          children: {
            0: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm,
                horizontal: AppSpacing.xs,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.place_rounded, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      '地點與集合',
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            1: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm,
                horizontal: AppSpacing.xs,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.groups_rounded, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      '成員與聯絡',
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          },
          onValueChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      );
    }

    return SizedBox(
      key: const Key('activity-detail-navigation'),
      width: double.infinity,
      child: SegmentedButton<int>(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(46)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          side: WidgetStateProperty.resolveWith((states) {
            return BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.45),
              width: 1,
            );
          }),
        ),
        segments: const [
          ButtonSegment(
            value: 0,
            icon: Icon(Icons.place_rounded, size: 16),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('地點與集合', maxLines: 1, softWrap: false),
            ),
          ),
          ButtonSegment(
            value: 1,
            icon: Icon(Icons.groups_rounded, size: 18),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('成員與聯絡', maxLines: 1, softWrap: false),
            ),
          ),
        ],
        selected: {index},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// 首屏唯一的狀態摘要。時間、地點（含投票中／鎖定結果）、集合地點與見面提示放在同一個
/// 可掃讀區塊，清楚區隔三層空間資訊，避免使用者先切分頁才能知道現在要做什麼。
class ActivityDetailStatusSummary extends ConsumerWidget {
  const ActivityDetailStatusSummary({
    super.key,
    required this.activity,
    this.locationOptions,
    this.locationVotes,
    this.fixtureLocations,
    this.meetingPointUpdates,
    this.myMeetingHint,
    this.currentTime,
    this.canMarkArrived,
  });

  final Activity activity;
  final List<ActivityLocationOption>? locationOptions;
  final List<ActivityLocationVote>? locationVotes;
  final List<Location>? fixtureLocations;
  final List<ActivityMeetingPointUpdate>? meetingPointUpdates;
  final String? myMeetingHint;
  final DateTime? currentTime;
  final bool? canMarkArrived;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final optionsAsync = locationOptions == null
        ? ref.watch(activityLocationOptionsStreamProvider(activity.id))
        : AsyncValue.data(locationOptions!);
    final votesAsync = locationVotes == null
        ? ref.watch(activityLocationVotesStreamProvider(activity.id))
        : AsyncValue.data(locationVotes!);
    final locationsAsync = fixtureLocations == null
        ? ref.watch(
            approvedLocationsProvider((activity.school, activity.campus)),
          )
        : AsyncValue.data(fixtureLocations!);
    final options = optionsAsync.value ?? const <ActivityLocationOption>[];
    final votes = votesAsync.value ?? const [];
    final locations = {
      for (final location in locationsAsync.value ?? const <Location>[])
        location.id: location,
    };

    String optionName(ActivityLocationOption option) =>
        option.customName ?? locations[option.locationId]?.name ?? '未命名地點';

    final locationLoading =
        optionsAsync.isLoading ||
        votesAsync.isLoading ||
        locationsAsync.isLoading;
    final locationError =
        optionsAsync.hasError || votesAsync.hasError || locationsAsync.hasError;
    final hasLocationOptions =
        activity.activityLocationId != null || options.isNotEmpty;

    final sorted = [...options]
      ..sort((a, b) {
        final bVotes = votes.where((vote) => vote.optionId == b.id).length;
        final aVotes = votes.where((vote) => vote.optionId == a.id).length;
        final voteOrder = bVotes.compareTo(aVotes);
        if (voteOrder != 0) return voteOrder;
        return a.createdAt.compareTo(b.createdAt);
      });
    final topVoteCount = sorted.isEmpty
        ? 0
        : votes.where((vote) => vote.optionId == sorted.first.id).length;
    final tiedOptions = sorted
        .where(
          (o) =>
              votes.where((vote) => vote.optionId == o.id).length ==
              topVoteCount,
        )
        .toList();
    final isTie =
        tiedOptions.length > 1 &&
        topVoteCount > 0 &&
        (activity.status == ACTIVITY_STATUS.MATCHED ||
            activity.status == ACTIVITY_STATUS.ONGOING);

    String locationSummary;
    if (locationLoading) {
      locationSummary = '活動地點：載入中';
    } else if (locationError) {
      locationSummary = '活動地點：暫時無法載入';
    } else if (options.isEmpty) {
      locationSummary = switch (activity.status) {
        ACTIVITY_STATUS.MATCHED || ACTIVITY_STATUS.ONGOING => '活動地點：等待提出候選地點',
        ACTIVITY_STATUS.COMPLETED => '活動地點：未設定',
        ACTIVITY_STATUS.CANCELLED => '活動地點：沒有地點記錄',
      };
    } else {
      // activity_location_id is maintained by the backend using the same
      // vote-count/earliest-proposal tie-break. Prefer that authoritative
      // value so the first viewport never disagrees with the voting cards.
      final authoritative = sorted.where(
        (option) => option.id == activity.activityLocationId,
      );
      final leader = authoritative.isEmpty ? sorted.first : authoritative.first;
      final leaderVotes = votes
          .where((vote) => vote.optionId == leader.id)
          .length;
      final tieSuffix = isTie ? '（平票中，等待其他成員投票決定）' : '';
      locationSummary = switch (activity.status) {
        ACTIVITY_STATUS.MATCHED || ACTIVITY_STATUS.ONGOING =>
          '活動地點（地點投票）：${optionName(leader)}目前領先（$leaderVotes 票，仍可變更）$tieSuffix',
        ACTIVITY_STATUS.COMPLETED ||
        ACTIVITY_STATUS.CANCELLED => '活動地點：${optionName(leader)}',
      };
    }

    final updatesAsync = meetingPointUpdates == null
        ? ref.watch(activityMeetingPointUpdatesStreamProvider(activity.id))
        : AsyncValue.data(meetingPointUpdates!);
    final updates = updatesAsync.value ?? const <ActivityMeetingPointUpdate>[];
    String? meetupSummary;
    if (activity.status != ACTIVITY_STATUS.CANCELLED) {
      if (updates.isEmpty) {
        meetupSummary = '集合地點：尚未設定（成團後由成員提議）';
      } else {
        final latest = updates.first;
        meetupSummary = updates.length > 1
            ? '集合地點：${latest.description}（已於 ${_hm(latest.createdAt.toLocal())} 更新）'
            : '集合地點：${latest.description}';
      }
    }

    final currentUserId = ref.watch(currentUserIdProvider);
    final hintsAsync = myMeetingHint == null
        ? ref.watch(activityMeetingHintStreamProvider(activity.id))
        : null;
    final hintMap = hintsAsync?.value;
    final effectiveHint =
        myMeetingHint ??
        (currentUserId != null && hintMap != null
            ? hintMap[currentUserId]
            : null);

    String? hintSummary;
    if (activity.status != ACTIVITY_STATUS.CANCELLED) {
      if (effectiveHint != null && effectiveHint.trim().isNotEmpty) {
        hintSummary = '見面提示：$effectiveHint';
      } else {
        hintSummary = '見面提示：尚未填寫（可到「成員與聯絡」說明衣著特徵以利相認）';
      }
    }

    final effectiveNow = currentTime ?? DateTime.now();
    final diff = activity.startTime.difference(effectiveNow);
    final isStartingSoon =
        (activity.status == ACTIVITY_STATUS.MATCHED ||
            activity.status == ACTIVITY_STATUS.ONGOING) &&
        diff.inMinutes >= 0 &&
        diff.inMinutes < 60;
    final isLocationUnsettled =
        options.isEmpty || activity.activityLocationId == null || isTie;
    final isMeetupUnsettled = updates.isEmpty;
    final showStartingSoonWarning =
        isStartingSoon && (isLocationUnsettled || isMeetupUnsettled);

    final buffer = StringBuffer();
    if (showStartingSoonWarning) {
      final missingParts = [
        if (isLocationUnsettled) '地點',
        if (isMeetupUnsettled) '集合方式',
      ].join('與');
      buffer.writeln('⚠️ 活動即將開始，但$missingParts尚未確定！請儘速確認。');
    }
    buffer.writeln('活動時間：${_activityTimeLabel(activity)}');
    buffer.writeln(locationSummary);
    if (meetupSummary != null) {
      buffer.writeln(meetupSummary);
    }
    if (hintSummary != null) {
      buffer.writeln(hintSummary);
    }

    final String deadlineText;
    if (canMarkArrived == true) {
      deadlineText = '下一步：抵達集合地點並點擊「我到了」';
    } else {
      deadlineText = _nextActionDescription(
        activity.status,
        hasLocationOptions: hasLocationOptions,
        locationLoading: locationLoading,
        locationError: locationError,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => AppStatusSummary(
        title: _activityStatusLabel(activity.status),
        message: buffer.toString().trim(),
        deadline: deadlineText,
        compact: true,
        inlineDeadline: constraints.maxWidth >= 600,
        leading: Icon(
          activity.status == ACTIVITY_STATUS.ONGOING
              ? Icons.play_circle_filled_rounded
              : activity.status == ACTIVITY_STATUS.COMPLETED
              ? Icons.check_circle_rounded
              : Icons.event_available_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class ActivityDetailStickyAction extends StatelessWidget {
  const ActivityDetailStickyAction({
    super.key,
    required this.status,
    required this.hasLocationOptions,
    required this.onPressed,
    this.locationLoading = false,
    this.locationError = false,
    this.customLabel,
    this.customIcon,
    this.sectionIndex = 0,
  });

  final ACTIVITY_STATUS status;
  final bool hasLocationOptions;
  final VoidCallback onPressed;
  final bool locationLoading;
  final bool locationError;
  final String? customLabel;
  final IconData? customIcon;
  final int sectionIndex;

  @override
  Widget build(BuildContext context) {
    final locationDependent =
        status == ACTIVITY_STATUS.MATCHED || status == ACTIVITY_STATUS.ONGOING;
    final effectiveLocationLoading = locationDependent && locationLoading;
    final effectiveLocationError = locationDependent && locationError;
    final label =
        customLabel ??
        _stickyActionLabel(
          status,
          hasLocationOptions: hasLocationOptions,
          locationLoading: effectiveLocationLoading,
          locationError: effectiveLocationError,
          sectionIndex: sectionIndex,
        );
    final icon =
        customIcon ??
        (effectiveLocationError
            ? Icons.refresh_rounded
            : sectionIndex == 1
            ? Icons.place_rounded
            : ((status == ACTIVITY_STATUS.MATCHED || status == ACTIVITY_STATUS.ONGOING) && !hasLocationOptions
                ? Icons.how_to_vote_outlined
                : Icons.groups_rounded));

    return AppStickyActionArea(
      child: AppButton(
        key: const Key('activity-detail-next-action'),
        label: label,
        icon: icon,
        loading: effectiveLocationLoading,
        onPressed: effectiveLocationLoading ? null : onPressed,
      ),
    );
  }
}

class ActivityManagementSection extends StatelessWidget {
  const ActivityManagementSection({
    super.key,
    required this.leaving,
    required this.onLeave,
  });

  final bool leaving;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: AppSection(
        title: '活動管理',
        description: '退出活動前會再次說明是否屬於 Early Cancel 或 Late Cancel，以及對配對冷卻與信譽的影響。',
        child: OutlinedButton.icon(
          key: const Key('activity-detail-leave'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
            minimumSize: const Size.fromHeight(52),
          ),
          onPressed: leaving ? null : onLeave,
          icon: leaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.exit_to_app_rounded),
          label: Text(leaving ? '正在退出活動' : '退出這個活動'),
        ),
      ),
    );
  }
}

class ActivityMemberSafetyActions extends StatelessWidget {
  const ActivityMemberSafetyActions({
    super.key,
    required this.blocking,
    required this.openingReport,
    required this.onBlock,
    required this.onReport,
  });

  final bool blocking;
  final bool openingReport;
  final VoidCallback onBlock;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return AppSection(
      title: '安全與管理',
      description: '封鎖後未來不會再配對在一起；檢舉會交由平台處理。',
      child: Column(
        children: [
          OutlinedButton.icon(
            key: const Key('activity-member-block'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: blocking ? null : onBlock,
            icon: blocking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.block_rounded),
            label: Text(blocking ? '封鎖中' : '封鎖'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            key: const Key('activity-member-report'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: openingReport ? null : onReport,
            icon: const Icon(Icons.flag_outlined),
            label: const Text('檢舉'),
          ),
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
  const _CompletionReportBanner({
    required this.activityId,
    required this.activityStatus,
    required this.contactVisibleUntil,
    required this.startTime,
  });

  final String activityId;
  final ACTIVITY_STATUS activityStatus;
  final DateTime contactVisibleUntil;
  final DateTime startTime;

  Future<void> _openRematchSheet(
    BuildContext context,
    WidgetRef ref,
    CompletionReport report,
  ) async {
    final myId = ref.read(currentUserIdProvider);
    final roster = await ref.read(
      activityMemberRosterProvider(activityId).future,
    );
    final rematchTargets = roster
        .where(
          (m) =>
              m.userId != myId &&
              m.status == ACTIVITY_MEMBER_STATUS.JOINED &&
              !report.absentUserIds.contains(m.userId),
        )
        .toList();
    if (!context.mounted) return;
    if (rematchTargets.isEmpty) {
      showAppSnackBar(context, '目前沒有其他可再約的成員');
      return;
    }
    await showAppSheet<void>(
      context,
      builder: (context) =>
          _RematchSheet(activityId: activityId, targets: rematchTargets),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(ownCompletionReportProvider(activityId));
    return reportAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: AppGlassSurface(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '無法載入回報狀態',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.invalidate(ownCompletionReportProvider(activityId)),
                child: const Text('重試'),
              ),
            ],
          ),
        ),
      ),
      data: (report) {
        if (report == null) {
          if (activityStatus != ACTIVITY_STATUS.ONGOING &&
              activityStatus != ACTIVITY_STATUS.COMPLETED) {
            return const SizedBox.shrink();
          }
          final fallbackWindowEnd = startTime.add(const Duration(hours: 24));
          final windowEnd = contactVisibleUntil.isAfter(fallbackWindowEnd)
              ? contactVisibleUntil
              : fallbackWindowEnd;
          if (!windowEnd.isAfter(DateTime.now())) {
            return const SizedBox.shrink();
          }
          final isCompleted = activityStatus == ACTIVITY_STATUS.COMPLETED;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppGlassSurface(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: AppSection(
                title: '活動完成回報',
                description: isCompleted
                    ? '活動已結束，花 10 秒回報出席狀況'
                    : '活動結束了嗎？花 10 秒回報一下',
                child: AppButton(
                  label: '開始回報',
                  icon: Icons.fact_check_outlined,
                  onPressed: () async {
                    final submitted = await showAppSheet<bool>(
                      context,
                      builder: (context) =>
                          _CompletionReportSheet(activityId: activityId),
                    );
                    if (submitted == true && context.mounted) {
                      showAppSnackBar(
                        context,
                        '活動回報已送出，謝謝你的回饋！',
                        kind: AppSnackKind.success,
                      );
                    }
                  },
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: AppGlassSurface(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '已完成活動回報',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '回報狀態已同步。想繼續保持聯繫嗎？雙方都點選「想再約」後將永久保留聯絡方式。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: '想再約其他成員',
                  icon: Icons.thumb_up_alt_outlined,
                  onPressed: () => _openRematchSheet(context, ref, report),
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
/// 檢查範圍）。
class _CompletionReportSheet extends ConsumerStatefulWidget {
  const _CompletionReportSheet({required this.activityId});

  final String activityId;

  @override
  ConsumerState<_CompletionReportSheet> createState() =>
      _CompletionReportSheetState();
}

class _CompletionReportSheetState
    extends ConsumerState<_CompletionReportSheet> {
  bool _pickingAbsent = false;
  final Set<String> _absentIds = {};
  bool _busy = false;
  String? _error;

  Future<void> _submit(
    COMPLETION_RESULT result, {
    List<String> absentUserIds = const [],
  }) async {
    if (_busy) return;
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
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.alreadyReported) {
        ref.invalidate(ownCompletionReportProvider(widget.activityId));
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = userErrorMessage(e));
      }
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
            final rosterAsync = ref.watch(
              activityMemberRosterProvider(widget.activityId),
            );
            final myId = ref.watch(currentUserIdProvider);
            return rosterAsync.when(
              loading: () =>
                  const SizedBox(height: 120, child: LoadingIndicator()),
              error: (error, stack) => const AppErrorState(),
              data: (roster) {
                final candidates = roster
                    .where(
                      (m) =>
                          m.userId != myId &&
                          m.status == ACTIVITY_MEMBER_STATUS.JOINED,
                    )
                    .toList();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '誰沒有出現？',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (candidates.isEmpty)
                      const Text('沒有其他成員可以指認')
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                            ],
                          ),
                        ),
                      ),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    AppButton(
                      label: '送出',
                      loading: _busy,
                      onPressed: _absentIds.isEmpty
                          ? null
                          : () => _submit(
                              COMPLETION_RESULT.REPORTED_ABSENT,
                              absentUserIds: _absentIds.toList(),
                            ),
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
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          ListTile(
            leading: const Icon(Icons.check_circle_outline_rounded),
            title: const Text('順利進行'),
            onTap: _busy ? null : () => _submit(COMPLETION_RESULT.WENT_WELL),
          ),
          ListTile(
            leading: const Icon(Icons.cancel_outlined),
            title: const Text('對方沒來'),
            onTap: _busy ? null : () => setState(() => _pickingAbsent = true),
          ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline_rounded),
            title: const Text('我自己取消了'),
            onTap: _busy
                ? null
                : () => _submit(COMPLETION_RESULT.SELF_CANCELLED),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.sm),
              child: LoadingIndicator(),
            ),
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
    final persistedVotes =
        ref.read(ownRematchVotesProvider(widget.activityId)).value ??
        const <String>{};
    if (_busy.contains(toUserId) ||
        _voted.contains(toUserId) ||
        persistedVotes.contains(toUserId)) {
      return;
    }
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
        showAppSnackBar(
          context,
          '雙方都按了再約，永久保留聯絡方式囉！',
          kind: AppSnackKind.success,
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        showAppSnackBar(context, userErrorMessage(e), kind: AppSnackKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(toUserId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final persistedVotes =
        ref.watch(ownRematchVotesProvider(widget.activityId)).value ??
        const <String>{};

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
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in widget.targets)
                    ListTile(
                      key: ValueKey(m.userId),
                      contentPadding: EdgeInsets.zero,
                      leading: SizedBox(
                        width: 40,
                        height: 40,
                        child: CircleAvatar(
                          backgroundImage: m.avatarUrl.isEmpty
                              ? null
                              : NetworkImage(m.avatarUrl),
                          child: m.avatarUrl.isEmpty
                              ? const Icon(Icons.person_rounded)
                              : null,
                        ),
                      ),
                      title: Text(
                        m.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(64, 44),
                        ),
                        onPressed:
                            _voted.contains(m.userId) ||
                                persistedVotes.contains(m.userId) ||
                                _busy.contains(m.userId)
                            ? null
                            : () => _vote(m.userId),
                        child: Text(
                          _voted.contains(m.userId) ||
                                  persistedVotes.contains(m.userId)
                              ? '已再約'
                              : '👍 再約',
                        ),
                      ),
                    ),
                ],
              ),
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
  const _LocationTab({
    super.key,
    required this.activity,
    required this.onLeave,
    required this.leaving,
    this.votingKey,
  });

  final Activity activity;
  final VoidCallback? onLeave;
  final bool leaving;
  final GlobalKey<_LocationVotingState>? votingKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit =
        activity.status == ACTIVITY_STATUS.MATCHED ||
        activity.status == ACTIVITY_STATUS.ONGOING;
    return AdaptiveRefresh(
      onRefresh: () async => ref.invalidate(
        approvedLocationsProvider((activity.school, activity.campus)),
      ),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList.list(
            children: [
              AppGlassSurface(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: AppSection(
                  title: '地點投票',
                  description: '查看即時票數、投票，或提出新的候選地點。',
                  child: _LocationVoting(key: votingKey, activity: activity),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppGlassSurface(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: AppSection(
                  title: '集合地點',
                  description: '以最新一筆更新為準；活動成員都會即時看到。',
                  child: _MeetingPointSection(
                    activityId: activity.id,
                    editable: canEdit,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppGlassSurface(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: AppSection(
                  title: '給同伴的話',
                  description: '可以說明穿著、帶了什麼或有沒有場地；同組成員都看得到，只有你能修改。',
                  child: _MeetingHintSection(
                    activityId: activity.id,
                    editable: canEdit,
                  ),
                ),
              ),
              if (onLeave != null) ...[
                const SizedBox(height: AppSpacing.md),
                ActivityManagementSection(leaving: leaving, onLeave: onLeave!),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Low-frequency gateway action for proposing a reusable official location.
/// Its busy state is intentionally independent from location voting and
/// one-off candidate creation, and is acquired before opening the dialog so
/// rapid taps cannot start parallel dialog/RPC flows.
class ActivityOfficialLocationProposalAction extends StatefulWidget {
  const ActivityOfficialLocationProposalAction({
    super.key,
    required this.onPropose,
  });

  final Future<void> Function(String name) onPropose;

  @override
  State<ActivityOfficialLocationProposalAction> createState() =>
      _ActivityOfficialLocationProposalActionState();
}

class _ActivityOfficialLocationProposalActionState
    extends State<ActivityOfficialLocationProposalAction> {
  bool _busy = false;

  Future<void> _openAndSubmit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final nameController = TextEditingController();
    try {
      final submitted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AppAdaptiveDialog(
          title: '建議加入官方地點清單',
          content: AppTextField(
            controller: nameController,
            label: '地點名稱',
            autofocus: true,
          ),
          actions: [
            AppDialogAction(
              label: '取消',
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            AppDialogAction(
              label: '送出',
              isDefault: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        ),
      );
      if (submitted != true || !mounted) return;
      final name = nameController.text.trim();
      if (name.isEmpty) return;

      await widget.onPropose(name);
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已送出「$name」，審核通過後才能投給這裡（這場活動想馬上投票，改用「新增這場活動的候選地點」）',
        kind: AppSnackKind.success,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.duplicateLocationName
          ? '這個地點已經存在了'
          : userErrorMessage(e);
      showAppSnackBar(context, message, kind: AppSnackKind.error);
    } finally {
      nameController.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const Key('activity-official-location-proposal'),
      onPressed: _busy ? null : _openAndSubmit,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('這個地點以後也會用到？建議加入官方清單'),
    );
  }
}

class _LocationVoting extends ConsumerStatefulWidget {
  const _LocationVoting({super.key, required this.activity});

  final Activity activity;

  @override
  ConsumerState<_LocationVoting> createState() => _LocationVotingState();
}

class _LocationVotingState extends ConsumerState<_LocationVoting> {
  bool _busy = false;
  String? _error;

  void triggerProposeSheet() {
    final locationsAsync = ref.read(
      approvedLocationsProvider((
        widget.activity.school,
        widget.activity.campus,
      )),
    );
    final optionsAsync = ref.read(
      activityLocationOptionsStreamProvider(widget.activity.id),
    );
    final options = optionsAsync.value ?? <ActivityLocationOption>[];
    _openProposeSheet(
      locationsAsync.value ?? [],
      options
          .where((o) => o.locationId != null)
          .map((o) => o.locationId!)
          .toSet(),
    );
  }

  Future<void> _vote(String optionId) async {
    if (_busy) return;
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
      setState(() => _error = userErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _propose(String locationId) async {
    if (_busy) return;
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
      setState(() => _error = userErrorMessage(e));
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
    if (_busy) return;
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
            AppTextField(
              controller: nameController,
              label: '地點名稱',
              autofocus: true,
              maxLength: 40,
            ),
          ],
        ),
        actions: [
          AppDialogAction(
            label: '取消',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppDialogAction(
            label: '新增並投票',
            isDefault: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
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
      setState(() => _error = userErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProposeSheet(
    List<Location> allLocations,
    Set<String> proposedIds,
  ) async {
    if (_busy) return;
    final candidates = allLocations
        .where((l) => !proposedIds.contains(l.id))
        .toList();
    final picked = await showAppSheet<String>(
      context,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        final textTheme = theme.textTheme;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '提出這場活動的地點',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '可從校園核准地點選擇，或自訂僅此活動專用的地點',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.edit_location_alt_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
                title: const Text('自訂其他地點（免審核）'),
                subtitle: const Text('例如校外咖啡廳、桌遊店，馬上可投'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                tileColor: scheme.primaryContainer.withValues(alpha: 0.15),
                onTap: () => Navigator.of(sheetContext).pop('__CUSTOM__'),
              ),
              const SizedBox(height: AppSpacing.md),
              if (candidates.isNotEmpty) ...[
                Text(
                  '校園核准地點',
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                for (final loc in candidates)
                  ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(loc.name),
                    dense: true,
                    onTap: () => Navigator.of(sheetContext).pop(loc.id),
                  ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    '這個校區的核准地點都已經是候選了',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    if (picked == '__CUSTOM__') {
      await _proposeCustom();
    } else {
      await _propose(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final optionsAsync = ref.watch(
      activityLocationOptionsStreamProvider(widget.activity.id),
    );
    final votesAsync = ref.watch(
      activityLocationVotesStreamProvider(widget.activity.id),
    );
    final locationsAsync = ref.watch(
      approvedLocationsProvider((
        widget.activity.school,
        widget.activity.campus,
      )),
    );
    final userId = ref.watch(currentUserIdProvider);

    if (optionsAsync.isLoading ||
        votesAsync.isLoading ||
        locationsAsync.isLoading) {
      return const AppCard(child: LoadingIndicator());
    }
    final optionsError =
        optionsAsync.hasError || votesAsync.hasError || locationsAsync.hasError;
    if (optionsError) {
      return const AppCard(child: Text('載入失敗'));
    }

    final options = optionsAsync.value ?? <ActivityLocationOption>[];
    final votes = votesAsync.value ?? [];
    final locations = {
      for (final l in locationsAsync.value ?? <Location>[]) l.id: l,
    };
    final myVotes = votes.where((v) => v.userId == userId).toList();
    final myVoteOptionId = myVotes.isEmpty ? null : myVotes.first.optionId;

    final maxVotes = options.isEmpty
        ? 0
        : options
              .map((o) => votes.where((v) => v.optionId == o.id).length)
              .reduce((a, b) => a > b ? a : b);
    final tiedLeaders = maxVotes > 0
        ? options
              .where(
                (o) =>
                    votes.where((v) => v.optionId == o.id).length == maxVotes,
              )
              .toList()
        : <ActivityLocationOption>[];
    final isTopTied = tiedLeaders.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isTopTied)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.balance_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '目前有 ${tiedLeaders.length} 個地點平手（各 $maxVotes 票）；依提案先後暫列，仍可調整投票。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (options.isEmpty)
          const AppCard(child: Text('還沒有人提案候選地點'))
        else
          for (final option in options) ...[
            AppCard(
              key: ValueKey(option.id),
              // v1.37：activity_location_id 是即時計算出的目前領先候選（不是
              // 投票截止後才鎖定的凍結值），這裡標出來讓大家知道「現在是這個
              // 領先」，但不代表投票已經結束——大家還是可以繼續投票把它換掉。
              child: Row(
                children: [
                  if (option.id == widget.activity.activityLocationId ||
                      (isTopTied &&
                          tiedLeaders.any((o) => o.id == option.id))) ...[
                    Icon(
                      isTopTied
                          ? Icons.balance_rounded
                          : Icons.chat_bubble_rounded,
                      size: 16,
                      color: isTopTied
                          ? Theme.of(context).colorScheme.tertiary
                          : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      option.customName ??
                          locations[option.locationId]?.name ??
                          '（地點）',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            (option.id == widget.activity.activityLocationId ||
                                (isTopTied &&
                                    tiedLeaders.any((o) => o.id == option.id)))
                            ? FontWeight.bold
                            : null,
                      ),
                    ),
                  ),
                  Text(
                    '${votes.where((v) => v.optionId == option.id).length} 票',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(64, 44),
                    ),
                    onPressed: _busy || myVoteOptionId == option.id
                        ? null
                        : () => _vote(option.id),
                    child: Text(myVoteOptionId == option.id ? '已投' : '投給這裡'),
                  ),
                ],
              ),
            ),
            if (isTopTied && tiedLeaders.any((o) => o.id == option.id))
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.sm,
                  bottom: AppSpacing.xs,
                ),
                child: Text(
                  '目前平手領先（各 $maxVotes 票，仍可調整投票）',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else if (option.id == widget.activity.activityLocationId)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.sm,
                  bottom: AppSpacing.xs,
                ),
                child: Text(
                  '目前領先（投票隨時可能改變結果）',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
          ],
        const SizedBox(height: AppSpacing.sm),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        if (options.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '目前尚未有候選地點，請點擊下方「提出地點」為活動提名集合地。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _openProposeSheet(
                    locationsAsync.value ?? [],
                    options
                        .where((o) => o.locationId != null)
                        .map((o) => o.locationId!)
                        .toSet(),
                  ),
            icon: const Icon(Icons.add_location_alt_outlined, size: 18),
            label: const Text('提出其他候選地點'),
          ),
        const SizedBox(height: AppSpacing.xs),
        ActivityOfficialLocationProposalAction(
          onPropose: (name) async {
            await proposeLocation(
              ref.read(supabaseClientProvider),
              name: name,
              school: widget.activity.school,
              campus: widget.activity.campus,
            );
          },
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
  ConsumerState<_MeetingPointSection> createState() =>
      _MeetingPointSectionState();
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
    if (_busy) return;
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
            : userErrorMessage(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updatesAsync = ref.watch(
      activityMeetingPointUpdatesStreamProvider(widget.activityId),
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          updatesAsync.when(
            loading: () => const LoadingIndicator(),
            error: (error, stack) => const AppErrorState(),
            data: (updates) => updates.isEmpty
                ? Text(
                    '目前還沒有人設定集合地點',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                // 反饋：「集合點現在的要再明顯一點，讓大家知道這是現在的集合
                // 點」——原本只是一行跟輸入框同一個視覺層級的小字，容易被當成
                // 表單的一部分而不是「這是目前生效的值」。改用跟 _LocationVoting
                // 「目前領先」同一套語言（主色系 + 粗體），但這裡是唯一值不是
                // 候選列表，直接用實心底色的區塊而不只是一行標籤文字，跟下面
                // 用來「送出新值」的輸入框明確分成兩層。
                : Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.pin_drop_rounded,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '目前集合地點',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            if (updates.length > 1) ...[
                              const SizedBox(width: AppSpacing.xs),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '已於 ${_hm(updates.first.createdAt.toLocal())} 更新',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onErrorContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          updates.first.description,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        if (updates.length > 1) ...[
                          const SizedBox(height: 4),
                          Text(
                            '集合地點曾有變更，請依最新地點會合，避免在原位置撲空。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer
                                      .withValues(alpha: 0.8),
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          if (widget.editable) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '更新集合地點',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            AppTextField(
              controller: _controller,
              hint: '例如：正門警衛室旁',
              maxLength: 40,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
  ConsumerState<_MeetingHintSection> createState() =>
      _MeetingHintSectionState();
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
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final client = ref.read(supabaseClientProvider);
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '無法載入給同伴的話';
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
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
      showAppSnackBar(context, '已更新給同伴的話', kind: AppSnackKind.success);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorMessage(e));
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
          _controller.text.isEmpty ? '（沒有留下訊息）' : _controller.text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            controller: _controller,
            hint: '例如：我有場地、會帶球；穿紅衣',
            maxLength: 30,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '更新給同伴的話', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}

/// UI_PLAN.md §4.1 Tab 2——成員名單依 `source_request_id` 分組顯示「一起
/// 來的」，每張卡片點開後顯示聯絡方式（依 `get_activity_contacts` 的
/// 24h/再約規則決定是否可見）＋封鎖／檢舉入口。
class MembersTab extends ConsumerWidget {
  const MembersTab({
    super.key,
    required this.activityId,
    required this.activityStatus,
    required this.activityTypeId,
  });

  final String activityId;
  final ACTIVITY_STATUS activityStatus;
  final String activityTypeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rosterAsync = ref.watch(activityMemberRosterProvider(activityId));
    final arrivalOverride = ref
        .watch(activityArrivalStreamProvider(activityId))
        .value;
    final vibeTagsOverride = ref
        .watch(activityVibeTagsStreamProvider(activityId))
        .value;
    final meetingHintOverride = ref
        .watch(activityMeetingHintStreamProvider(activityId))
        .value;
    final showArrival =
        activityStatus == ACTIVITY_STATUS.MATCHED ||
        activityStatus == ACTIVITY_STATUS.ONGOING;
    final typesAsync = ref.watch(activityTypesProvider);
    final matchingTypes =
        typesAsync.value?.where((t) => t.id == activityTypeId) ??
        const Iterable.empty();
    final activityTypeName = matchingTypes.isEmpty
        ? ''
        : matchingTypes.first.name;

    final myId = ref.watch(currentUserIdProvider);

    return rosterAsync.when(
      loading: () => const LoadingIndicator(),
      error: (error, stack) => const AppErrorState(),
      data: (rawRoster) {
        final roster = [
          for (final member in rawRoster)
            () {
              var m = member;
              if (arrivalOverride != null &&
                  arrivalOverride.containsKey(m.userId)) {
                m = m.copyWithArrivedAt(arrivalOverride[m.userId]);
              }
              if (vibeTagsOverride != null &&
                  vibeTagsOverride.containsKey(m.userId)) {
                m = m.copyWithVibeTags(vibeTagsOverride[m.userId]!);
              }
              if (meetingHintOverride != null &&
                  meetingHintOverride.containsKey(m.userId)) {
                m = m.copyWithMeetingHint(meetingHintOverride[m.userId]);
              }
              return m;
            }(),
        ];
        final groups = <String, List<MemberRosterEntry>>{};
        for (final member in roster) {
          groups.putIfAbsent(member.sourceRequestId, () => []).add(member);
        }
        final joinedCount = roster
            .where((m) => m.status == ACTIVITY_MEMBER_STATUS.JOINED)
            .length;
        final cancelledCount = roster
            .where((m) => m.status == ACTIVITY_MEMBER_STATUS.CANCELLED)
            .length;
        final arrivedCount = roster
            .where(
              (m) =>
                  m.status == ACTIVITY_MEMBER_STATUS.JOINED &&
                  m.arrivedAt != null,
            )
            .length;
        final myMember = roster.where((m) => m.userId == myId).firstOrNull;
        final isMyMemberJoined =
            myMember != null &&
            myMember.status == ACTIVITY_MEMBER_STATUS.JOINED;
        final hasMyArrived = myMember?.arrivedAt != null;

        return AdaptiveRefresh(
          onRefresh: () async =>
              ref.invalidate(activityMemberRosterProvider(activityId)),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              sliver: SliverList.list(
                children: [
                  if (cancelledCount > 0) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .errorContainer
                            .withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .error
                              .withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.person_off_rounded,
                            size: 20,
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '已有 $cancelledCount 位夥伴退出本次活動',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onErrorContainer,
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '目前活動成員剩餘 $joinedCount 人，活動仍可照常進行。若人數不足也可至活動管理選擇退出。',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onErrorContainer,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (showArrival && joinedCount > 0) ...[
                    AppGlassSurface(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: AppSection(
                        title: '報到狀態',
                        description: isMyMemberJoined
                            ? (hasMyArrived
                                  ? '你已完成報到，請在集合點與夥伴會合。'
                                  : '抵達集合地點後，請點擊「我到了」完成報到。')
                            : '抵達集合地點後，完成報到即可讓夥伴知道你已到達。',
                        child: AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.flag_circle_rounded,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      '已抵達 $arrivedCount / $joinedCount',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                  if (isMyMemberJoined && !hasMyArrived)
                                    _ArrivalButton(activityId: activityId),
                                ],
                              ),
                              if (isMyMemberJoined && hasMyArrived) ...[
                                const SizedBox(height: AppSpacing.sm),
                                const Divider(height: 1),
                                const SizedBox(height: AppSpacing.sm),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_rounded,
                                      size: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: AppSpacing.xs),
                                    Expanded(
                                      child: Text(
                                        '你已於 ${_hm(myMember.arrivedAt!.toLocal())} 完成報到',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  AppGlassSurface(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: AppSection(
                      title: '活動成員',
                      description: '點擊卡片認識夥伴、交換聯絡方式 ✨ 也可以設定自己的風格標籤喔！',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (groups.isEmpty)
                            const Text('目前沒有可顯示的成員')
                          else
                            for (final group in groups.values) ...[
                              if (group.length > 1) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 3.5,
                                  ),
                                  margin: const EdgeInsets.only(
                                    bottom: AppSpacing.xs,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                        .withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.diversity_3_rounded,
                                        size: 13,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '同組出發夥伴',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
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
                    ),
                  ),
                ],
              ),
            ),
          ],
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
  bool _blocking = false;
  bool _openingReport = false;
  bool _vibeBusy = false;

  Future<void> _confirmBlock() async {
    if (_blocking) return;
    final confirmed = await showAppConfirmDialog(
      context,
      title: '封鎖這位成員？',
      message: '封鎖後，未來不會再被配對在一起。這個動作不會通知對方。',
      confirmLabel: '封鎖',
      isDestructive: true,
    );
    if (!confirmed) return;
    if (_blocking) return;
    setState(() => _blocking = true);
    try {
      await blockUser(
        ref.read(supabaseClientProvider),
        blockedId: widget.member.userId,
      );
    } on ApiException {
      // 冪等 RPC，這輪不特別處理錯誤——安靜失敗，使用者可再試一次；不影響
      // 「成功後安靜關閉選單」這個非歸因設計（SPEC §12.1.2 精神的延伸）。
    } finally {
      if (mounted) {
        setState(() {
          _blocking = false;
          _expanded = false;
        });
      }
    }
  }

  Future<void> _openReportSheet() async {
    if (_openingReport) return;
    setState(() => _openingReport = true);
    await showAppSheet<void>(
      context,
      builder: (context) => _ReportSheet(reportedUserId: widget.member.userId),
    );
    if (!mounted) return;
    setState(() {
      _openingReport = false;
      _expanded = false;
    });
  }

  Future<void> _editVibeTags() async {
    if (_vibeBusy) return;
    final options = _vibeTagOptionsFor(widget.activityTypeName);
    // Tag 描述參與風格；裝備、場地等即時資訊由「給同伴的話」傳達。
    // 保留自訂風格標籤，後端仍只驗證數量與長度。
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
            title: '你的參與風格',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '最多 3 個，可自訂風格；裝備、場地資訊請寫在「給同伴的話」。',
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
                        onSelected: AppHaptics.select(
                          (value) => setDialogState(() {
                            if (value) {
                              if (selected.length < 3) selected.add(option);
                            } else {
                              selected.remove(option);
                            }
                          }),
                        ),
                      ),
                    for (final tag in selected.where(
                      (t) => !options.contains(t),
                    ))
                      InputChip(
                        label: Text(tag),
                        onDeleted: () =>
                            setDialogState(() => selected.remove(tag)),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: textController,
                  maxLength: 20,
                  enabled: selected.length < 3,
                  decoration: InputDecoration(
                    hintText: selected.length >= 3 ? '最多 3 個標籤' : '例如：慢步調',
                    isDense: true,
                    counterText: '',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add_rounded),
                      tooltip: '新增標籤',
                      onPressed: selected.length >= 3
                          ? null
                          : () => addCustomTag(textController.text),
                    ),
                  ),
                  onSubmitted: addCustomTag,
                ),
              ],
            ),
            actions: [
              AppDialogAction(
                label: '取消',
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              AppDialogAction(
                label: '儲存',
                isDefault: true,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_vibeBusy) return;

    setState(() => _vibeBusy = true);
    try {
      await updateVibeTags(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
        tags: selected,
      );
      ref.invalidate(activityMemberRosterProvider(widget.activityId));
    } on ApiException {
      if (!mounted) return;
      showAppSnackBar(context, '儲存失敗，請再試一次', kind: AppSnackKind.error);
    } finally {
      if (mounted) setState(() => _vibeBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final userId = ref.watch(currentUserIdProvider);
    final isSelf = member.userId == userId;
    final isCancelled = member.status == ACTIVITY_MEMBER_STATUS.CANCELLED;
    final showArrival =
        widget.activityStatus == ACTIVITY_STATUS.MATCHED ||
        widget.activityStatus == ACTIVITY_STATUS.ONGOING;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelf
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.45),
          width: isSelf ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: isSelf
              ? () => showAppSheet<void>(
                  context,
                  builder: (context) => _ProfileCardSheet(member: member),
                )
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (member.meetingHint != null &&
                    member.meetingHint!.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: _MeetingHintBubble(text: member.meetingHint!),
                  ),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      button: true,
                      label: '查看 ${isSelf ? '自己' : member.displayName} 的個人資料',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(28),
                        onTap: () => showAppSheet<void>(
                          context,
                          builder: (context) => _ProfileCardSheet(member: member),
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: isSelf
                                      ? [scheme.primary, scheme.tertiary]
                                      : member.arrivedAt != null
                                          ? [
                                              scheme.primary,
                                              scheme.primaryContainer
                                            ]
                                          : [
                                              scheme.outlineVariant
                                                  .withValues(alpha: 0.6),
                                              scheme.surfaceContainerHighest,
                                            ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 22,
                                backgroundColor: scheme.surfaceContainerHighest,
                                backgroundImage: member.avatarUrl.isEmpty
                                    ? null
                                    : NetworkImage(member.avatarUrl),
                                child: member.avatarUrl.isEmpty
                                    ? Icon(
                                        Icons.person_rounded,
                                        color: scheme.onSurfaceVariant,
                                        size: 22,
                                      )
                                    : null,
                              ),
                            ),
                            if (member.arrivedAt != null)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(1.5),
                                  decoration: BoxDecoration(
                                    color: scheme.surface,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.check,
                                      size: 9,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        isSelf
                                            ? '${member.displayName}（你）'
                                            : member.displayName,
                                        style:
                                            theme.textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isSelf) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: scheme.primaryContainer,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '本人',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: scheme.onPrimaryContainer,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (!isSelf &&
                                  widget.activityStatus ==
                                      ACTIVITY_STATUS.COMPLETED &&
                                  !isCancelled) ...[
                                _RematchButton(
                                  activityId: widget.activityId,
                                  toUserId: member.userId,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                              if (!isSelf)
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest
                                        .withValues(alpha: 0.5),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    _expanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    size: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                          // F28：若頂部氣泡已顯示見面提示，此處不重複顯示自身想說的話；僅在未填寫時提示
                          if (isSelf && (member.meetingHint == null || member.meetingHint!.isEmpty)) ...[
                            const SizedBox(height: 3),
                            Text(
                              '給夥伴的見面提示：尚未填寫（點頭像可補充）',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 5,
                            runSpacing: 4,
                            children: [
                              _CuteBadge(
                                icon: Icons.school_rounded,
                                label:
                                    '${schoolLabel(member.school)} · ${member.department ?? '未填科系'} · ${_degreeLabel(member.degreeLevel)}',
                              ),
                              _ReliabilityBadge(
                                tier: member.reliabilityTier,
                                isCancelled: isCancelled,
                              ),
                              if (member.sportLevel != null)
                                _CuteBadge(
                                  icon: Icons.fitness_center_rounded,
                                  label: SportLevelConfig.format(
                                    member.levelSystem,
                                    member.sportLevel,
                                    rating: member.sportLevelRating,
                                  ),
                                ),
                              if (member.studyTarget != null &&
                                  member.studyTarget!.isNotEmpty)
                                _CuteBadge(
                                  icon: Icons.menu_book_rounded,
                                  label: '讀書目標：${member.studyTarget}',
                                ),
                              if (showArrival && !isCancelled)
                                _CuteArrivalBadge(
                                  arrivedAt: member.arrivedAt,
                                ),
                            ],
                          ),
                          if (member.vibeTags.isNotEmpty ||
                              (isSelf && !isCancelled)) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final tag in member.vibeTags)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.secondaryContainer
                                          .withValues(alpha: 0.35),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: scheme.secondary
                                            .withValues(alpha: 0.2),
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      '#$tag',
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
                                        color: scheme.onSecondaryContainer,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                if (isSelf && !isCancelled)
                                  ActionChip(
                                    avatar: Icon(
                                      member.vibeTags.isEmpty
                                          ? Icons.auto_awesome_rounded
                                          : Icons.edit_rounded,
                                      size: 13,
                                      color: scheme.primary,
                                    ),
                                    label: Text(
                                      member.vibeTags.isEmpty
                                          ? '設定參與風格'
                                          : '編輯風格',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.primary,
                                      ),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      side: BorderSide(
                                        color: scheme.primary
                                            .withValues(alpha: 0.35),
                                        width: 1,
                                      ),
                                    ),
                                    visualDensity: const VisualDensity(
                                      horizontal: -2,
                                      vertical: -2,
                                    ),
                                    onPressed: _vibeBusy ? null : _editVibeTags,
                                  ),
                              ],
                            ),
                          ],
                          if (isSelf &&
                              showArrival &&
                              !isCancelled &&
                              member.arrivedAt == null) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Align(
                              alignment: Alignment.centerRight,
                              child: _ArrivalButton(activityId: widget.activityId),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (_expanded && !isSelf) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Divider(height: 1),
                  const SizedBox(height: AppSpacing.md),
                  AppSection(
                    title: '聯絡方式',
                    child: ActivityMemberContactSection(
                        contacts: member.contacts),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ActivityMemberSafetyActions(
                    blocking: _blocking,
                    openingReport: _openingReport,
                    onBlock: _confirmBlock,
                    onReport: _openReportSheet,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CuteBadge extends StatelessWidget {
  const _CuteBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReliabilityBadge extends StatelessWidget {
  const _ReliabilityBadge({required this.tier, this.isCancelled = false});
  final ReliabilityTier tier;
  final bool isCancelled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (isCancelled) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '已取消參加 · 可信度 ${_tierLabel(tier)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onErrorContainer,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      );
    }

    final (icon, tierText, bg, fg) = switch (tier) {
      ReliabilityTier.newUser => (
        '🌱',
        tier.displayLabel,
        scheme.secondaryContainer.withValues(alpha: 0.5),
        scheme.onSecondaryContainer,
      ),
      ReliabilityTier.normal => (
        '🤝',
        tier.displayLabel,
        scheme.tertiaryContainer.withValues(alpha: 0.5),
        scheme.onTertiaryContainer,
      ),
      ReliabilityTier.trusted => (
        '🛡️',
        tier.displayLabel,
        scheme.primaryContainer.withValues(alpha: 0.5),
        scheme.onPrimaryContainer,
      ),
      ReliabilityTier.unknown => (
        '✨',
        tier.displayLabel,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$icon $tierText',
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _CuteArrivalBadge extends StatelessWidget {
  const _CuteArrivalBadge({required this.arrivedAt});
  final DateTime? arrivedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isArrived = arrivedAt != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: isArrived
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isArrived ? Icons.check_circle_rounded : Icons.schedule_rounded,
            size: 13,
            color: isArrived ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            isArrived
                ? '已於 ${_hm(arrivedAt!.toLocal())} 抵達'
                : '尚未抵達',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isArrived ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: isArrived ? FontWeight.w600 : FontWeight.normal,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// 見面提示漫畫講話框——貼在成員頭像正上方，不用展開卡片就看得到。
class _MeetingHintBubble extends StatelessWidget {
  const _MeetingHintBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  scheme.primaryContainer.withValues(alpha: 0.9),
                  scheme.primaryContainer.withValues(alpha: 0.7),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomRight: Radius.circular(14),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.12),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chat_bubble_rounded,
                  size: 12,
                  color: scheme.primary,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    text,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: CustomPaint(
              size: const Size(10, 5),
              painter: _BubblePointerPainter(
                color: scheme.primaryContainer.withValues(alpha: 0.85),
                borderColor: scheme.primary.withValues(alpha: 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BubblePointerPainter extends CustomPainter {
  _BubblePointerPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BubblePointerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.borderColor != borderColor;
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
              backgroundImage: member.avatarUrl.isEmpty
                  ? null
                  : NetworkImage(member.avatarUrl),
              child: member.avatarUrl.isEmpty
                  ? const Icon(Icons.person_rounded, size: 40)
                  : null,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Text(
              member.displayName,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '${schoolLabel(member.school)} · ${member.department ?? '未填科系'} · ${_degreeLabel(member.degreeLevel)}',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: Text(
              '可信度 ${_tierLabel(member.reliabilityTier)}',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (member.sportLevel != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                SportLevelConfig.format(
                  member.levelSystem,
                  member.sportLevel,
                  rating: member.sportLevelRating,
                ),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (member.studyTarget != null && member.studyTarget!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                '讀書目標：${member.studyTarget}',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Text(
            '自我介紹',
            style: textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
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
    if (_busy) return;
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
        showAppSnackBar(
          context,
          '雙方都按了再約，永久保留聯絡方式囉！',
          kind: AppSnackKind.success,
        );
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
        minimumSize: const Size(64, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
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

  // 反饋：使用者擔心手滑點到「我到了」——一旦標記，系統會立刻通知其他成員
  // 「XX 已抵達」，不像其他欄位（集合地點/提示）可以再改一次蓋掉，事後
  // 沒有回頭路能收回已經送出去的通知，所以用點擊前二次確認，不做「標記後
  // 允許復原」（復原也沒辦法讓其他成員已讀到的通知消失，只會製造「他到底
  // 有沒有到」的混亂）。
  Future<void> _confirmAndMarkArrived() async {
    if (_busy) return;
    final confirmed = await showAppConfirmDialog(
      context,
      title: '確定你已經到了嗎？',
      message: '按下後會立刻通知其他成員你已抵達，無法收回。',
      confirmLabel: '我到了',
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await markArrived(
        ref.read(supabaseClientProvider),
        activityId: widget.activityId,
      );
      AppHaptics.success();
      if (mounted) {
        showAppSnackBar(
          context,
          '已完成報到！已通知其他成員你已抵達。',
          kind: AppSnackKind.success,
        );
      }
    } on ApiException {
      if (mounted) {
        showAppSnackBar(context, '標記失敗，請再試一次', kind: AppSnackKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _busy ? null : _confirmAndMarkArrived,
      style: FilledButton.styleFrom(
        minimumSize: const Size(112, 42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(21),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
      ),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.near_me_rounded, size: 18),
      label: Text(
        _busy ? '標記中…' : '我到了',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class ActivityMemberContactSection extends StatelessWidget {
  const ActivityMemberContactSection({super.key, required this.contacts});

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
      if (contacts!.contactDiscord != null)
        ('Discord', contacts!.contactDiscord!),
    ];
    if (lines.isEmpty) {
      return Text('對方沒有留下聯絡方式', style: Theme.of(context).textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in lines)
          _ContactLine(label: label, value: value),
      ],
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
            child: Text(
              '$label: $value',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: '複製',
            visualDensity: const VisualDensity(horizontal: -2, vertical: -1),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              showAppSnackBar(context, '已複製 $label');
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
    if (_busy) return;
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
      setState(() => _error = userErrorMessage(e));
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
          Text(
            '檢舉類別',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final category in REPORT_CATEGORY.values)
                ChoiceChip(
                  label: Text(_reportCategoryLabel(category)),
                  selected: _category == category,
                  onSelected: (selected) {
                    if (selected) {
                      AppHaptics.selection();
                      setState(() => _category = category);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(controller: _detailController, hint: '選填：補充說明'),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '送出檢舉', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}
