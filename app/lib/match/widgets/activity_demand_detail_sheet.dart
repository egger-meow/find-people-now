import 'package:flutter/material.dart';

import '../../data/activity_type_icons.dart';
import '../../data/sport_level_config.dart';
import '../../rpc/campus_demand_rpc.dart';
import '../../theme/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_sheet.dart';

/// 點擊匿名需求卡彈出的條件確認面板（v1.43）
///
/// 讓使用者完整檢視此匿名需求的所有條件（活動、校區、時間範圍、程度、人數），
/// 並透過「我也想去」建立參與承諾；或透過「以此條件微調」帶入表單自訂。
Future<void> showActivityDemandDetailSheet(
  BuildContext context, {
  required CampusDemandCard demand,
  required bool canParticipate,
  String? disabledReason,
  required VoidCallback onParticipate,
  required VoidCallback onCustomize,
  DateTime? relativeNow,
}) {
  return showAppSheet(
    context,
    builder: (sheetContext) => ActivityDemandDetailSheet(
      demand: demand,
      canParticipate: canParticipate,
      disabledReason: disabledReason,
      onParticipate: onParticipate,
      onCustomize: onCustomize,
      relativeNow: relativeNow,
    ),
  );
}

class ActivityDemandDetailSheet extends StatelessWidget {
  const ActivityDemandDetailSheet({
    super.key,
    required this.demand,
    required this.canParticipate,
    this.disabledReason,
    required this.onParticipate,
    required this.onCustomize,
    this.relativeNow,
  });

  final CampusDemandCard demand;
  final bool canParticipate;
  final String? disabledReason;
  final VoidCallback onParticipate;
  final VoidCallback onCustomize;
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

    final levelLabel = demand.studyTarget != null
        ? '科目：${demand.studyTarget}'
        : _formatLevel(
            demand.activityTypeName,
            demand.sportLevel,
            demand.sportLevelRating,
          );

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
                  activityTypeIcon(demand.activityTypeName),
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
                      demand.activityTypeName,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '匿名活動需求確認',
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

          // 條件明細卡
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              children: [
                _DetailRow(
                  icon: Icons.calendar_today_rounded,
                  label: '可開始時段',
                  value: demand.timeSlotLabel(relativeTo: relativeNow),
                ),
                const Divider(height: AppSpacing.md),
                _DetailRow(
                  icon: Icons.location_on_outlined,
                  label: '活動校區',
                  value: demand.campus,
                ),
                const Divider(height: AppSpacing.md),
                _DetailRow(
                  icon: Icons.tune_rounded,
                  label: '程度 / 條件',
                  value: levelLabel,
                ),
                const Divider(height: AppSpacing.md),
                _DetailRow(
                  icon: Icons.group_outlined,
                  label: '人數規模',
                  value: demand.maxParticipants != null
                      ? '${demand.minParticipants} 至 ${demand.maxParticipants} 人'
                      : '${demand.minParticipants} 人以上',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 整合式配對說明與盲配承諾（避免重複框層疊，消除「加入指定團體」之誤解）
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        '${demand.honestSignalText}。點擊「以相容條件加入配對」將以相同條件為你送出配對需求，由系統在背景撮合相容夥伴，並非直接加入特定私人小組。',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        '撮合完全依條件進行；若為兩人配對，確認階段僅提供基本安全資訊核對，成團前絕不公開任何外部聯絡方式。',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 若無法參與（有進行中配對/活動），顯示說明
          if (!canParticipate && disabledReason != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                disabledReason!,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],

          // 操作按鈕：以相容條件加入配對 + 調整條件後發起
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: '以相容條件加入配對',
              icon: Icons.how_to_reg_outlined,
              onPressed: canParticipate
                  ? () {
                      AppHaptics.tap();
                      Navigator.of(context).pop();
                      onParticipate();
                    }
                  : null,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                AppHaptics.selection();
                Navigator.of(context).pop();
                onCustomize();
              },
              child: const Text('調整條件後發起...'),
            ),
          ),

        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2.0),
          child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
