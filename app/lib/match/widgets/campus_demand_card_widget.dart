import 'package:flutter/material.dart';

import '../../data/activity_type_icons.dart';
import '../../data/sport_level_config.dart';
import '../../rpc/campus_demand_rpc.dart';
import '../../theme/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

/// 匿名活動需求卡元件（v1.43）
///
/// 首頁核心決策介面的主角：
/// 清楚呈現「哪個活動、哪個時間、哪個校區、何種程度有人想去」，
/// 並提供直觀的「看看條件」入口，點擊可直接建立承諾加入。
/// 遵守盲配原則：卡片上絕無大頭照、性別、學歷或挑人按鈕。
class CampusDemandCardWidget extends StatelessWidget {
  const CampusDemandCardWidget({
    super.key,
    required this.demand,
    this.onTap,
    this.relativeNow,
  });

  final CampusDemandCard demand;
  final VoidCallback? onTap;
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
    return config?.formatLevel(sportLevel, short: true, rating: rating) ??
        sportLevel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final levelLabel = demand.studyTarget != null
        ? '科目：${demand.studyTarget}'
        : _formatLevel(
            demand.activityTypeName,
            demand.sportLevel,
            demand.sportLevelRating,
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        onTap: onTap != null
            ? () {
                AppHaptics.tap();
                onTap!();
              }
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 頂部列：活動圖示 + 名稱 + 時間徽章
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.xs + 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    activityTypeIcon(demand.activityTypeName),
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    demand.activityTypeName,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    demand.timeSlotLabel(relativeTo: relativeNow),
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // 條件 Chips：校區、程度、人數範圍
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                _CriterionChip(
                  icon: Icons.location_on_outlined,
                  label: demand.campus,
                ),
                _CriterionChip(
                  icon: Icons.tune_rounded,
                  label: levelLabel,
                ),
                _CriterionChip(
                  icon: Icons.group_outlined,
                  label: demand.headcountRangeLabel,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // 底部列：客觀誠實訊號 + 查看詳情按鈕（明確回答「多少人在等」與「我如何參與」）
            Row(
              children: [
                Icon(
                  Icons.people_outline_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    demand.honestSignalText,
                    style: textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onTap != null
                      ? () {
                          AppHaptics.tap();
                          onTap!();
                        }
                      : null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    minimumSize: const Size(44, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看詳情'),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded, size: 16),
                    ],
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

class _CriterionChip extends StatelessWidget {
  const _CriterionChip({
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
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
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
