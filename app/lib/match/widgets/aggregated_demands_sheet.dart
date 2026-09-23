import 'package:flutter/material.dart';

import '../../data/activity_type_icons.dart';
import '../../data/sport_level_config.dart';
import '../../rpc/campus_demand_rpc.dart';
import '../../theme/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_sheet.dart';

/// 點擊多組聚合摘要卡彈出的相容條件清單 sheet（iOS UX 指南 §7）
///
/// 呈現精簡的相容條件列：時段、科目／程度、人數範圍。
/// 點選某一列才進既有條件確認與加入流程；不得暗選第一組。
Future<void> showAggregatedDemandsSheet(
  BuildContext context, {
  required AggregatedDemandGroup group,
  required ValueChanged<CampusDemandCard> onSelectDemand,
  DateTime? relativeNow,
}) {
  return showAppSheet(
    context,
    builder: (sheetContext) => AggregatedDemandsSheet(
      group: group,
      onSelectDemand: onSelectDemand,
      relativeNow: relativeNow,
    ),
  );
}

class AggregatedDemandsSheet extends StatelessWidget {
  const AggregatedDemandsSheet({
    super.key,
    required this.group,
    required this.onSelectDemand,
    this.relativeNow,
  });

  final AggregatedDemandGroup group;
  final ValueChanged<CampusDemandCard> onSelectDemand;
  final DateTime? relativeNow;

  String _formatLevel(String activityName, String? sportLevel, int? rating) {
    if (sportLevel == null) {
      return activityName == '練舞' ? '不限曲風' : '不限程度';
    }
    final config = switch (activityName) {
      '羽球' => SportLevelConfig.badminton,
      '籃球' => SportLevelConfig.basketball,
      '網球' => SportLevelConfig.tennis,
      '桌球' => SportLevelConfig.tableTennis,
      '練舞' => SportLevelConfig.dance,
      _ => null,
    };
    return config?.formatLevel(sportLevel, rating: rating) ?? sportLevel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題列
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  activityTypeIcon(group.activityTypeName),
                  size: 24,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${group.activityTypeName} · ${group.campus}',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '共 ${group.demands.length} 組相容時段與程度條件',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // 提示說明
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '請點選合適的時段與程度，確認後送出配對',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 條件列清單
          for (var i = 0; i < group.demands.length; i++) ...[
            _DemandOptionTile(
              demand: group.demands[i],
              levelLabel: group.demands[i].studyTarget != null
                  ? '科目：${group.demands[i].studyTarget}'
                  : _formatLevel(
                      group.activityTypeName,
                      group.demands[i].sportLevel,
                      group.demands[i].sportLevelRating,
                    ),
              relativeNow: relativeNow,
              onTap: () {
                AppHaptics.selection();
                Navigator.of(context).pop();
                onSelectDemand(group.demands[i]);
              },
            ),
            if (i < group.demands.length - 1)
              const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _DemandOptionTile extends StatelessWidget {
  const _DemandOptionTile({
    required this.demand,
    required this.levelLabel,
    required this.onTap,
    this.relativeNow,
  });

  final CampusDemandCard demand;
  final String levelLabel;
  final VoidCallback onTap;
  final DateTime? relativeNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    demand.timeSlotLabel(relativeTo: relativeNow),
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                _OptionChip(
                  icon: Icons.tune_rounded,
                  label: levelLabel,
                ),
                _OptionChip(
                  icon: Icons.group_outlined,
                  label: demand.headcountRangeLabel,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            Row(
              children: [
                Icon(
                  Icons.people_outline_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    demand.honestSignalText,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
