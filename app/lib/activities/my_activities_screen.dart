import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../generated/activity.dart';
import '../generated/supadart_header.dart' show ACTIVITY_STATUS, REQUEST_STATUS;
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/loading_indicator.dart';
import 'my_activities_providers.dart';
import 'pending_confirmation_card.dart';

String _requestStatusLabel(REQUEST_STATUS status) => switch (status) {
      REQUEST_STATUS.DRAFT => '草稿',
      REQUEST_STATUS.REQUESTING => '等待配對中',
      REQUEST_STATUS.PENDING_CONFIRMATION => '小人數確認中',
      REQUEST_STATUS.MATCHED => '已成團',
      REQUEST_STATUS.EXPIRED => '未成局',
      REQUEST_STATUS.CANCELLED => '已取消',
    };

String _activityStatusLabel(ACTIVITY_STATUS status) => switch (status) {
      ACTIVITY_STATUS.MATCHED => '已成團，等待開始',
      ACTIVITY_STATUS.ONGOING => '進行中',
      ACTIVITY_STATUS.COMPLETED => '已完成',
      ACTIVITY_STATUS.CANCELLED => '已取消',
    };

/// UI_PLAN.md §4「我的活動」清單殼——round 1：REQUESTING/PENDING_CONFIRMATION/
/// EXPIRED/CANCELLED 四種狀態的完整卡片；round 2：MATCHED/ONGOING 的卡片
/// 可點入單一活動的地點分頁籤（見 activity_detail_screen.dart）。COMPLETED
/// 的完成確認/再約流程、以及地點以外的成員分頁籤，留給後續幾輪。
class MyActivitiesScreen extends StatelessWidget {
  const MyActivitiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('我的活動'),
          bottom: const TabBar(tabs: [Tab(text: '進行中'), Tab(text: '已結束')]),
        ),
        body: const SafeArea(
          child: TabBarView(
            children: [
              _ActivityList(showOngoing: true),
              _ActivityList(showOngoing: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityList extends ConsumerWidget {
  const _ActivityList({required this.showOngoing});

  final bool showOngoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(myActivityListProvider);

    return listAsync.when(
      loading: () => const LoadingIndicator(),
      error: (error, stack) => Center(child: Text('載入失敗：$error')),
      data: (items) {
        final filtered = items.where((item) => item.isOngoing == showOngoing).toList();
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(myActivityListProvider),
          child: filtered.isEmpty
              ? ListView(
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: Center(
                        child: Text(showOngoing ? '目前沒有進行中的活動' : '還沒有已結束的活動'),
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) => _ActivityListEntry(item: filtered[index]),
                ),
        );
      },
    );
  }
}

class _ActivityListEntry extends StatelessWidget {
  const _ActivityListEntry({required this.item});

  final MyActivityListItem item;

  @override
  Widget build(BuildContext context) {
    if (item.kind == MyActivityKind.request) {
      final request = item.request!;
      switch (request.status) {
        case REQUEST_STATUS.REQUESTING:
          return AppCard(
            onTap: () => context.go('/waiting-room/${request.id}'),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_requestStatusLabel(request.status)),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          );
        case REQUEST_STATUS.PENDING_CONFIRMATION:
          return PendingConfirmationCard(requestId: request.id);
        case REQUEST_STATUS.EXPIRED:
        case REQUEST_STATUS.CANCELLED:
          return AppCard(
            child: Text(
              _requestStatusLabel(request.status),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          );
        case REQUEST_STATUS.DRAFT:
        case REQUEST_STATUS.MATCHED:
          // 不應出現：myMatchRequestsProvider 的查詢已排除這兩個狀態。
          return const SizedBox.shrink();
      }
    }

    final activity = item.activity!;
    return _PlaceholderActivityCard(activity: activity);
  }
}

/// MATCHED/ONGOING 的 Activity 可點入 `/activity/:id`（`ActivityDetailScreen`，
/// UI_PLAN §4.1，round 2：地點分頁籤；成員分頁籤下一輪才會做）。
/// COMPLETED/CANCELLED 這輪只做到「清單抓得到、分頁分對」，完成確認/再約
/// 流程留給後續幾輪，所以不做可點擊的導覽。
class _PlaceholderActivityCard extends StatelessWidget {
  const _PlaceholderActivityCard({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final isActive = activity.status == ACTIVITY_STATUS.MATCHED || activity.status == ACTIVITY_STATUS.ONGOING;
    return AppCard(
      onTap: isActive ? () => context.go('/activity/${activity.id}') : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_activityStatusLabel(activity.status), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${activity.school.name} · ${activity.campus}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (isActive) const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}
