import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generated/supadart_header.dart' show SCHOOL;
import '../../rpc/campus_demand_rpc.dart';
import '../../theme/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/skeleton.dart';
import '../match_providers.dart';
import 'campus_demand_card_widget.dart';

/// 首頁核心決策專區——「校園即時揪團動態」（v1.43）
///
/// 呈現指定校區底下的匿名活動需求卡，包含：
/// 1. 校區無縫切換（多校區學校）
/// 2. 時間維度篩選（全部 / 現在 / 今天 / 明天）
/// 3. 四態完整處理：骨架載入 (Loading)、真實空狀態 (Empty)、連線錯誤 (Error)、資料清單 (Data)
/// 4. 點擊需求卡進入條件檢視與「我也想去」直達流程
class CampusDemandsSection extends ConsumerWidget {
  const CampusDemandsSection({
    super.key,
    required this.school,
    required this.campus,
    required this.availableCampuses,
    required this.onSelectCampus,
    required this.onSelectDemand,
    required this.onCreateNewRequest,
    required this.onSetAlert,
    this.canParticipate = true,
    this.disabledReason,
    this.relativeNow,
  });

  final SCHOOL school;
  final String campus;
  final List<String> availableCampuses;
  final ValueChanged<String> onSelectCampus;
  final void Function(CampusDemandCard demand) onSelectDemand;
  final VoidCallback onCreateNewRequest;
  final VoidCallback onSetAlert;
  final bool canParticipate;
  final String? disabledReason;
  final DateTime? relativeNow;

  Future<void> _showCampusPicker(BuildContext context) async {
    if (availableCampuses.length <= 1) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppAdaptiveDialog(
        title: '選擇校區',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in availableCampuses)
              ListTile(
                title: Text(c),
                trailing: c == campus
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(dialogContext).pop(c),
              ),
          ],
        ),
        actions: [
          AppDialogAction(
            label: '取消',
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );

    if (selected != null && selected != campus) {
      AppHaptics.selection();
      onSelectCampus(selected);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final demandsAsync = ref.watch(campusDemandsProvider((school, campus)));
    final activeFilter = ref.watch(selectedTimeFilterProvider);
    final lastUpdated = ref.watch(campusDemandsLastUpdatedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 區塊頂部：標題 + 校區切換按鈕
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 22,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  '校園即時揪團動態',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            if (availableCampuses.length > 1)
              InkWell(
                onTap: () => _showCampusPicker(context),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 14,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        campus,
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              )
            else
              Text(
                campus,
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '先找到一起做的事，再認識一起做的人。',
          style: textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),

        // 時間維度篩選列
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final filter in DemandTimeFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: ChoiceChip(
                    label: Text(
                      filter.label,
                      softWrap: false,
                      maxLines: 1,
                    ),
                    selected: activeFilter == filter,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (selected) {
                      if (selected) {
                        AppHaptics.selection();
                        ref
                            .read(selectedTimeFilterProvider.notifier)
                            .setFilter(filter);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // 四態渲染：Loading / Error / Empty / Data
        if (demandsAsync.hasError)
          AppCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    color: scheme.error,
                    size: 28,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '暫時無法取得校園揪團動態',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '請檢查網路連線或稍後再試',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      AppHaptics.tap();
                      ref.invalidate(campusDemandsProvider((school, campus)));
                    },
                    child: const Text('重試'),
                  ),
                ],
              ),
            ),
          )
        else
          demandsAsync.when(
            loading: () => const Column(
              children: [
                _SkeletonDemandCard(),
                SizedBox(height: AppSpacing.sm),
                _SkeletonDemandCard(),
              ],
            ),
            error: (err, stack) => const SizedBox.shrink(),
            data: (demands) {
            final filtered = demands
                .where((d) => d.matchesFilter(activeFilter, relativeTo: relativeNow))
                .toList();

            if (filtered.isEmpty) {
              return AppCard(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.explore_outlined,
                        size: 40,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '目前$campus還沒有人在揪',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '當第一個發起的人，或是設定提醒，有人發起時通知你！',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(120, 44),
                            ),
                            onPressed: () {
                              AppHaptics.tap();
                              onCreateNewRequest();
                            },
                            child: const Text('自己揪一個'),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.notifications_active_outlined, size: 16),
                            label: const Text('設定時效提醒'),
                            onPressed: () {
                              AppHaptics.selection();
                              onSetAlert();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lastUpdated != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      '共 ${filtered.length} 個即時活動等待相容夥伴 · 剛剛更新',
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final demand in filtered)
                  CampusDemandCardWidget(
                    demand: demand,
                    relativeNow: relativeNow,
                    onTap: () => onSelectDemand(demand),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SkeletonDemandCard extends StatelessWidget {
  const _SkeletonDemandCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Skeleton(width: 32, height: 32, radius: AppRadius.sm),
              SizedBox(width: AppSpacing.sm),
              Expanded(child: Skeleton(height: 20)),
              SizedBox(width: AppSpacing.sm),
              Skeleton(width: 80, height: 20, radius: AppRadius.pill),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: const [
              Skeleton(width: 60, height: 22),
              Skeleton(width: 70, height: 22),
              Skeleton(width: 70, height: 22),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Expanded(child: Skeleton(height: 16)),
              SizedBox(width: AppSpacing.sm),
              Skeleton(width: 60, height: 16),
            ],
          ),
        ],
      ),
    );
  }
}
