import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/activity_type_icons.dart';
import '../data/school_labels.dart';
import '../generated/supadart_header.dart' show ACTIVITY_STATUS, REQUEST_STATUS;
import '../match/match_providers.dart' show activityTypesProvider;
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
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

/// 卡片語意色調——跟文字狀態標籤一起用（不單靠顏色傳達意義），四種狀態各自
/// 對應一種「這件事現在對使用者來說是什麼心情」：active＝還在等待/已確定但
/// 未開始，live＝現在正在發生，done＝已經結束（中性，不代表好壞），
/// muted＝這條路徑沒有下文了（未成局/已取消）。
enum _CardTone { active, live, done, muted }

Color _toneContainer(_CardTone tone, ColorScheme scheme) => switch (tone) {
      _CardTone.active => scheme.primaryContainer,
      _CardTone.live => scheme.tertiaryContainer,
      _CardTone.done => scheme.surfaceContainerHighest,
      _CardTone.muted => scheme.surfaceContainerHighest,
    };

Color _toneOnContainer(_CardTone tone, ColorScheme scheme) => switch (tone) {
      _CardTone.active => scheme.onPrimaryContainer,
      _CardTone.live => scheme.onTertiaryContainer,
      _CardTone.done => scheme.onSurfaceVariant,
      _CardTone.muted => scheme.onSurfaceVariant,
    };

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _dayPrefix(DateTime local, DateTime todayDate) {
  final target = DateTime(local.year, local.month, local.day);
  if (target == todayDate) return '今天';
  if (target == todayDate.add(const Duration(days: 1))) return '明天';
  if (target == todayDate.subtract(const Duration(days: 1))) return '昨天';
  return '${local.month}/${local.day}';
}

/// 活動的單一時間點（`start_time`）——「今天 14:00」／「8/1 14:00」。
String _formatPoint(DateTime dt) {
  final local = dt.toLocal();
  final todayDate = DateTime.now();
  return '${_dayPrefix(local, DateTime(todayDate.year, todayDate.month, todayDate.day))} ${_hm(local)}';
}

/// Request 的時間區間（`earliest_start`~`latest_start`）——「今天 14:00–18:00」。
String _formatWindow(DateTime a, DateTime b) {
  final aLocal = a.toLocal();
  final bLocal = b.toLocal();
  final todayDate = DateTime.now();
  final prefix = _dayPrefix(aLocal, DateTime(todayDate.year, todayDate.month, todayDate.day));
  return '$prefix ${_hm(aLocal)}–${_hm(bLocal)}';
}

/// UI_PLAN.md §4「我的活動」清單殼——round 1：REQUESTING/PENDING_CONFIRMATION/
/// EXPIRED/CANCELLED 四種狀態的完整卡片；round 2：MATCHED/ONGOING 的卡片
/// 可點入單一活動的地點分頁籤；round 3 補上成員分頁籤；round 4 補上
/// COMPLETED（完成確認彈窗＋再約按鈕，見 activity_detail_screen.dart）—— 連帶
/// 讓 CANCELLED 也能點進去（同一個畫面，地點/見面提示的編輯欄位會依狀態隱藏
/// 唯讀顯示，純粹只是能不能再看歷史紀錄的問題，沒有理由單獨排除）。
///
/// UI/UX 補強：這是使用者最常回來確認「有沒有找到人」的畫面，原本每張卡片
/// 只有一行狀態文字（甚至叫 `_PlaceholderActivityCard`，名符其實從未真正做完）
/// ——跟等待室/安全確認卡（已經有 icon、時間、人數等完整資訊）比起來明顯沒做
/// 完。這裡補上活動類型 icon＋名稱、時間、校區、色調化狀態標籤，並讓空清單
/// 有明確的下一步（見 [_EmptyState]），而不是一片空白文字。
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
    final typesAsync = ref.watch(activityTypesProvider);
    final typeNames = {for (final t in typesAsync.value ?? const []) t.id: t.name};

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
                      child: showOngoing
                          ? _EmptyState(
                              icon: Icons.explore_outlined,
                              message: '目前沒有進行中的活動',
                              ctaLabel: '找人一起做點事',
                              onCta: () => context.go('/match'),
                            )
                          : const _EmptyState(
                              icon: Icons.history_rounded,
                              message: '還沒有已結束的活動\n完成的活動會出現在這裡',
                            ),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) => _ActivityListEntry(
                    key: ValueKey(filtered[index].id),
                    item: filtered[index],
                    typeName: typeNames[filtered[index].activityTypeId] ?? '活動',
                  ),
                ),
        );
      },
    );
  }
}

class _ActivityListEntry extends StatelessWidget {
  const _ActivityListEntry({super.key, required this.item, required this.typeName});

  final MyActivityListItem item;
  final String typeName;

  @override
  Widget build(BuildContext context) {
    if (item.kind == MyActivityKind.request) {
      final request = item.request!;
      switch (request.status) {
        case REQUEST_STATUS.REQUESTING:
          return _ActivityCard(
            icon: activityTypeIcon(typeName),
            typeName: typeName,
            timeLabel: _formatWindow(request.earliestStart, request.latestStart),
            campusLabel: '${schoolLabel(request.school)} ${request.campus}',
            statusLabel: _requestStatusLabel(request.status),
            tone: _CardTone.active,
            onTap: () => context.push('/waiting-room/${request.id}'),
          );
        case REQUEST_STATUS.PENDING_CONFIRMATION:
          return PendingConfirmationCard(requestId: request.id);
        case REQUEST_STATUS.EXPIRED:
        case REQUEST_STATUS.CANCELLED:
          return _ActivityCard(
            icon: activityTypeIcon(typeName),
            typeName: typeName,
            timeLabel: _formatWindow(request.earliestStart, request.latestStart),
            campusLabel: '${schoolLabel(request.school)} ${request.campus}',
            statusLabel: _requestStatusLabel(request.status),
            tone: _CardTone.muted,
          );
        case REQUEST_STATUS.DRAFT:
        case REQUEST_STATUS.MATCHED:
          // 不應出現：myMatchRequestsProvider 的查詢已排除這兩個狀態。
          return const SizedBox.shrink();
      }
    }

    final activity = item.activity!;
    final tone = switch (activity.status) {
      ACTIVITY_STATUS.MATCHED => _CardTone.active,
      ACTIVITY_STATUS.ONGOING => _CardTone.live,
      ACTIVITY_STATUS.COMPLETED => _CardTone.done,
      ACTIVITY_STATUS.CANCELLED => _CardTone.muted,
    };
    return _ActivityCard(
      icon: activityTypeIcon(typeName),
      typeName: typeName,
      timeLabel: _formatPoint(activity.startTime),
      campusLabel: '${schoolLabel(activity.school)} ${activity.campus}',
      statusLabel: _activityStatusLabel(activity.status),
      tone: tone,
      onTap: () => context.push('/activity/${activity.id}'),
    );
  }
}

/// 統一卡片——Request（REQUESTING/EXPIRED/CANCELLED）跟 Activity（MATCHED/
/// ONGOING/COMPLETED/CANCELLED）共用同一套視覺語言：icon 色塊（跟狀態色調
/// 呼應）＋類型名稱＋時間＋校區＋狀態標籤，不因為資料來源不同而長得不一樣。
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.icon,
    required this.typeName,
    required this.timeLabel,
    required this.campusLabel,
    required this.statusLabel,
    required this.tone,
    this.onTap,
  });

  final IconData icon;
  final String typeName;
  final String timeLabel;
  final String campusLabel;
  final String statusLabel;
  final _CardTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final muted = tone == _CardTone.muted;

    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _toneContainer(tone, scheme),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(icon, size: 22, color: _toneOnContainer(tone, scheme)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        typeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    _StatusChip(label: statusLabel, tone: tone),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        timeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.location_on_rounded, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        campusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _CardTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: _toneContainer(tone, scheme),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: _toneOnContainer(tone, scheme),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 空清單狀態——icon＋文案＋（可選）主要行動按鈕，取代原本一行置中文字。
/// 「進行中」分頁空的時候直接給出下一步（去配對頁），呼應「使用者不該疑惑
/// 接下來要幹嘛」；「已結束」分頁單純是還沒有歷史紀錄，不需要 CTA。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message, this.ctaLabel, this.onCta});

  final IconData icon;
  final String message;
  final String? ctaLabel;
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (ctaLabel != null && onCta != null) ...[
              const SizedBox(height: AppSpacing.lg),
              SizedBox(width: 220, child: AppButton(label: ctaLabel!, onPressed: onCta)),
            ],
          ],
        ),
      ),
    );
  }
}
