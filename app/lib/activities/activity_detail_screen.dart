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
import '../rpc/auth_profile_rpc.dart' show ReliabilityTier;
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
}) => switch (status) {
  ACTIVITY_STATUS.MATCHED ||
  ACTIVITY_STATUS.ONGOING when locationLoading => '正在載入地點資訊',
  ACTIVITY_STATUS.MATCHED ||
  ACTIVITY_STATUS.ONGOING when locationError => '重新載入地點資訊',
  ACTIVITY_STATUS.MATCHED => hasLocationOptions ? '前往地點投票' : '前往提出候選地點',
  ACTIVITY_STATUS.ONGOING => hasLocationOptions ? '查看報到與成員' : '前往提出候選地點',
  ACTIVITY_STATUS.COMPLETED => '查看成員與再約',
  ACTIVITY_STATUS.CANCELLED => '查看活動紀錄',
};

int _stickyActionSection(
  ACTIVITY_STATUS status, {
  required bool hasLocationOptions,
}) => switch (status) {
  ACTIVITY_STATUS.MATCHED || ACTIVITY_STATUS.CANCELLED => 0,
  ACTIVITY_STATUS.ONGOING => hasLocationOptions ? 1 : 0,
  ACTIVITY_STATUS.COMPLETED => 1,
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
class ActivityDetailScreen extends ConsumerStatefulWidget {
  const ActivityDetailScreen({super.key, required this.activityId});

  final String activityId;

  @override
  ConsumerState<ActivityDetailScreen> createState() =>
      _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends ConsumerState<ActivityDetailScreen> {
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
            return ActivityDetailBodyLayout(
              summary: ActivityDetailStatusSummary(activity: activity),
              completionBanner: activity.status == ACTIVITY_STATUS.ONGOING
                  ? _CompletionReportBanner(activityId: activity.id)
                  : null,
              navigation: _ActivityDetailNavigation(
                index: _sectionIndex,
                onChanged: (value) => setState(() => _sectionIndex = value),
              ),
              content: IndexedStack(
                index: _sectionIndex,
                children: [
                  _LocationTab(
                    activity: activity,
                    leaving: _leaving,
                    onLeave:
                        activity.status == ACTIVITY_STATUS.MATCHED ||
                            activity.status == ACTIVITY_STATUS.ONGOING
                        ? () => _showCancelDialog(activity)
                        : null,
                  ),
                  _MembersTab(
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
                onPressed: () {
                  final locationNeedsReload =
                      (activity.status == ACTIVITY_STATUS.MATCHED ||
                          activity.status == ACTIVITY_STATUS.ONGOING) &&
                      locationError;
                  final target = _stickyActionSection(
                    activity.status,
                    hasLocationOptions: locationNeedsReload
                        ? false
                        : hasLocationOptions,
                  );
                  setState(() => _sectionIndex = target);
                  if (target == 0) {
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
                    ref.invalidate(activityMemberRosterProvider(activity.id));
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
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final header = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.md,
                    ),
                    child: AppGlassSurface(
                      padding: EdgeInsets.zero,
                      child: summary,
                    ),
                  ),
                  if (completionBanner != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      child: completionBanner!,
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: navigation,
                  ),
                ],
              );

              if (!keyboardVisible) {
                return Column(
                  children: [
                    header,
                    Expanded(child: content),
                  ],
                );
              }

              const minimumInteractiveHeight = 44.0;
              // Reserve a scrollable viewport for the selected tab before
              // choosing the header quota. On a short landscape viewport the
              // old 25% quota could collapse the header/navigation below the
              // 44pt accessibility target after the sticky keyboard inset.
              final maximumHeaderHeight =
                  (constraints.maxHeight - minimumInteractiveHeight).clamp(
                    0.0,
                    constraints.maxHeight,
                  );
              final minimumHeaderHeight = maximumHeaderHeight.clamp(
                0.0,
                minimumInteractiveHeight,
              );
              final preferredHeaderHeight = constraints.maxHeight * 0.25;
              final headerHeight = preferredHeaderHeight.clamp(
                minimumHeaderHeight,
                maximumHeaderHeight,
              );

              return Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: minimumHeaderHeight,
                      maxHeight: headerHeight,
                    ),
                    child: SingleChildScrollView(
                      key: const Key('activity-detail-header-scroll'),
                      child: header,
                    ),
                  ),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
        stickyAction,
      ],
    );
  }
}

class _ActivityDetailNavigation extends StatelessWidget {
  const _ActivityDetailNavigation({
    required this.index,
    required this.onChanged,
  });

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isCupertino) {
      return ConstrainedBox(
        key: const Key('activity-detail-navigation'),
        constraints: const BoxConstraints(minHeight: 44),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: index,
          children: const {
            0: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('地點與集合'),
            ),
            1: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('成員與聯絡'),
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
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.fromHeight(44)),
        ),
        segments: const [
          ButtonSegment(value: 0, label: Text('地點與集合')),
          ButtonSegment(value: 1, label: Text('成員與聯絡')),
        ],
        selected: {index},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// 首屏唯一的狀態摘要。時間、地點（含投票中／鎖定結果）與下一步放在同一個
/// 可掃讀區塊，避免使用者先切分頁才能知道現在要做什麼。
class ActivityDetailStatusSummary extends ConsumerWidget {
  const ActivityDetailStatusSummary({
    super.key,
    required this.activity,
    this.locationOptions,
    this.locationVotes,
    this.fixtureLocations,
  });

  final Activity activity;
  final List<ActivityLocationOption>? locationOptions;
  final List<ActivityLocationVote>? locationVotes;
  final List<Location>? fixtureLocations;

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
    String locationSummary;
    if (locationLoading) {
      locationSummary = '地點：載入中';
    } else if (locationError) {
      locationSummary = '地點：暫時無法載入';
    } else if (options.isEmpty) {
      locationSummary = switch (activity.status) {
        ACTIVITY_STATUS.MATCHED || ACTIVITY_STATUS.ONGOING => '地點：等待提出候選地點',
        ACTIVITY_STATUS.COMPLETED => '地點：活動未設定集合地點',
        ACTIVITY_STATUS.CANCELLED => '地點：沒有地點記錄',
      };
    } else {
      final sorted = [...options]
        ..sort((a, b) {
          final bVotes = votes.where((vote) => vote.optionId == b.id).length;
          final aVotes = votes.where((vote) => vote.optionId == a.id).length;
          final voteOrder = bVotes.compareTo(aVotes);
          if (voteOrder != 0) return voteOrder;
          return a.createdAt.compareTo(b.createdAt);
        });
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
      locationSummary = switch (activity.status) {
        ACTIVITY_STATUS.MATCHED || ACTIVITY_STATUS.ONGOING =>
          '地點投票：${optionName(leader)}目前領先（$leaderVotes 票，仍可變更）',
        ACTIVITY_STATUS.COMPLETED ||
        ACTIVITY_STATUS.CANCELLED => '地點：${optionName(leader)}',
      };
    }

    return LayoutBuilder(
      builder: (context, constraints) => AppStatusSummary(
        title: _activityStatusLabel(activity.status),
        message: '活動時間：${_activityTimeLabel(activity)}\n$locationSummary',
        deadline: _nextActionDescription(
          activity.status,
          hasLocationOptions: hasLocationOptions,
          locationLoading: locationLoading,
          locationError: locationError,
        ),
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
  });

  final ACTIVITY_STATUS status;
  final bool hasLocationOptions;
  final VoidCallback onPressed;
  final bool locationLoading;
  final bool locationError;

  @override
  Widget build(BuildContext context) {
    final locationDependent =
        status == ACTIVITY_STATUS.MATCHED || status == ACTIVITY_STATUS.ONGOING;
    final effectiveLocationLoading = locationDependent && locationLoading;
    final effectiveLocationError = locationDependent && locationError;
    return AppStickyActionArea(
      child: AppButton(
        key: const Key('activity-detail-next-action'),
        label: _stickyActionLabel(
          status,
          hasLocationOptions: hasLocationOptions,
          locationLoading: effectiveLocationLoading,
          locationError: effectiveLocationError,
        ),
        icon: effectiveLocationError
            ? Icons.refresh_rounded
            : status == ACTIVITY_STATUS.MATCHED
            ? Icons.how_to_vote_outlined
            : Icons.groups_rounded,
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
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: AppGlassSurface(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: AppSection(
              title: '活動完成回報',
              description: '活動結束了嗎？花 10 秒回報一下',
              child: AppButton(
                label: '開始回報',
                icon: Icons.fact_check_outlined,
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (context) =>
                      _CompletionReportSheet(activityId: activityId),
                ),
              ),
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
      Navigator.of(context).pop();

      final myId = ref.read(currentUserIdProvider);
      final roster = await ref.read(
        activityMemberRosterProvider(widget.activityId).future,
      );
      final rematchTargets = roster
          .where(
            (m) =>
                m.userId != myId &&
                m.status == ACTIVITY_MEMBER_STATUS.JOINED &&
                !absentUserIds.contains(m.userId),
          )
          .toList();
      if (!mounted || rematchTargets.isEmpty) return;
      await showAppSheet<void>(
        context,
        builder: (context) => _RematchSheet(
          activityId: widget.activityId,
          targets: rematchTargets,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == ApiErrorCode.alreadyReported
            ? '你已經回報過了'
            : userErrorMessage(e);
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
    if (_busy.contains(toUserId) || _voted.contains(toUserId)) return;
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
                onPressed: _voted.contains(m.userId) || _busy.contains(m.userId)
                    ? null
                    : () => _vote(m.userId),
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
  const _LocationTab({
    required this.activity,
    required this.onLeave,
    required this.leaving,
  });

  final Activity activity;
  final VoidCallback? onLeave;
  final bool leaving;

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
                  child: _LocationVoting(activity: activity),
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
                  title: '我的見面提示',
                  description: '讓對方認出你；同組成員都看得到，只有你能修改自己的提示。',
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
  const _LocationVoting({required this.activity});

  final Activity activity;

  @override
  ConsumerState<_LocationVoting> createState() => _LocationVotingState();
}

class _LocationVotingState extends ConsumerState<_LocationVoting> {
  bool _busy = false;
  String? _error;

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
              ListTile(
                title: Text(loc.name),
                onTap: () => Navigator.of(context).pop(loc.id),
              ),
          ],
        );
      },
    );
    if (picked != null) await _propose(picked);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                  if (option.id == widget.activity.activityLocationId) ...[
                    Icon(
                      Icons.chat_bubble_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
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
                            option.id == widget.activity.activityLocationId
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
            if (option.id == widget.activity.activityLocationId)
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
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _openProposeSheet(
                  locationsAsync.value ?? [],
                  options
                      .where((o) => o.locationId != null)
                      .map((o) => o.locationId!)
                      .toSet(),
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
      showAppSnackBar(context, '已更新見面提示', kind: AppSnackKind.success);
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
          _controller.text.isEmpty ? '（沒有填見面提示）' : _controller.text,
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
            hint: '例如：我會戴紅色棒球帽',
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
  const _MembersTab({
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
        final arrivedCount = roster
            .where(
              (m) =>
                  m.status == ACTIVITY_MEMBER_STATUS.JOINED &&
                  m.arrivedAt != null,
            )
            .length;
        return AdaptiveRefresh(
          onRefresh: () async =>
              ref.invalidate(activityMemberRosterProvider(activityId)),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              sliver: SliverList.list(
                children: [
                  if (showArrival && joinedCount > 0) ...[
                    AppGlassSurface(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: AppSection(
                        title: '報到狀態',
                        description: '抵達集合地點後，請在自己的成員卡片完成報到。',
                        child: AppCard(
                          child: Row(
                            children: [
                              Icon(
                                Icons.flag_circle_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Text(
                                  '已抵達 $arrivedCount / $joinedCount',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
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
                      description: '點選其他成員可查看聯絡方式、個人資料與安全操作。',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (groups.isEmpty)
                            const Text('目前沒有可顯示的成員')
                          else
                            for (final group in groups.values) ...[
                              if (group.length > 1) ...[
                                Text(
                                  '一起加入',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
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
                    hintText: selected.length >= 3 ? '最多 3 個標籤' : '輸入自訂標籤',
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

    return AppCard(
      onTap: isSelf ? null : () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 反饋：「見面提示我怎麼沒看到別人的更新」——原本只在展開卡片後才顯示
          // 一行小字，且對方不設定就完全看不到「這功能存在」的痕跡。改成不用
          // 展開就看得到、貼在頭像旁邊的漫畫講話框，非本人且有填才顯示。
          if (!isSelf &&
              member.meetingHint != null &&
              member.meetingHint!.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: _MeetingHintBubble(text: member.meetingHint!),
            ),
          ],
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
                    : () => showAppSheet<void>(
                        context,
                        builder: (context) => _ProfileCardSheet(member: member),
                      ),
                child: CircleAvatar(
                  radius: 22,
                  backgroundImage: member.avatarUrl.isEmpty
                      ? null
                      : NetworkImage(member.avatarUrl),
                  child: member.avatarUrl.isEmpty
                      ? const Icon(Icons.person_rounded)
                      : null,
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
                      isCancelled
                          ? '已取消參加 · 可信度 ${_tierLabel(member.reliabilityTier)}'
                          : '可信度 ${_tierLabel(member.reliabilityTier)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    // v1.34/v1.35/v1.42 — 該成員發起/加入配對當下指定的程度／讀書目標，
                    // 兩者互斥（分屬不同活動類型），非 null 才顯示。
                    if (member.sportLevel != null)
                      Text(
                        SportLevelConfig.format(
                          member.levelSystem,
                          member.sportLevel,
                          rating: member.sportLevelRating,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (member.studyTarget != null &&
                        member.studyTarget!.isNotEmpty)
                      Text(
                        '讀書目標：${member.studyTarget}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (showArrival && !isCancelled) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            member.arrivedAt != null
                                ? Icons.check_circle_rounded
                                : Icons.schedule_rounded,
                            size: 14,
                            color: member.arrivedAt != null
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            member.arrivedAt != null ? '已抵達' : '尚未抵達',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: member.arrivedAt != null
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ],
                    if (member.vibeTags.isNotEmpty ||
                        (isSelf && !isCancelled)) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final tag in member.vibeTags)
                            Chip(
                              label: Text(
                                tag,
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -1,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: EdgeInsets.zero,
                            ),
                          if (isSelf && !isCancelled)
                            ActionChip(
                              avatar: const Icon(Icons.add_rounded, size: 14),
                              label: Text(
                                member.vibeTags.isEmpty ? '設定參與方式' : '編輯',
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -1,
                              ),
                              onPressed: _vibeBusy ? null : _editVibeTags,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (!isSelf &&
                  widget.activityStatus == ACTIVITY_STATUS.COMPLETED &&
                  !isCancelled) ...[
                _RematchButton(
                  activityId: widget.activityId,
                  toUserId: member.userId,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              if (isSelf &&
                  showArrival &&
                  !isCancelled &&
                  member.arrivedAt == null)
                _ArrivalButton(activityId: widget.activityId),
              if (!isSelf)
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
            ],
          ),
          if (_expanded && !isSelf) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),
            AppSection(
              title: '聯絡方式',
              child: ActivityMemberContactSection(contacts: member.contacts),
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
    );
  }
}

/// 見面提示漫畫講話框——貼在成員頭像正上方，不用展開卡片就看得到，取代原本
/// 埋在展開區塊裡的一行小字。純展示用（沒有互動），用 Stack 疊一個旋轉 45°
/// 的小方塊當講話框尾巴，跟主體同色，指向下方的頭像。
class _MeetingHintBubble extends StatelessWidget {
  const _MeetingHintBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            bottom: -5,
            child: Transform.rotate(
              angle: 0.78539816339744830961, // 45°
              child: Container(
                width: 10,
                height: 10,
                color: scheme.primaryContainer,
              ),
            ),
          ),
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
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44)),
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
        minimumSize: const Size(112, 44),
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
          DropdownButtonFormField<REPORT_CATEGORY>(
            initialValue: _category,
            items: [
              for (final category in REPORT_CATEGORY.values)
                DropdownMenuItem(
                  value: category,
                  child: Text(_reportCategoryLabel(category)),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _category = value);
            },
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
