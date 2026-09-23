import 'package:flutter/material.dart';

import '../generated/supadart_header.dart';
import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';

String degreeLevelLabel(DEGREE_LEVEL level) => switch (level) {
      DEGREE_LEVEL.UNDERGRAD => '大學部',
      DEGREE_LEVEL.MASTER => '碩士班',
      DEGREE_LEVEL.PHD => '博士班',
    };

/// 學制選擇元件：以受控的 SegmentedButton 提供「大學部 / 碩士班 / 博士班」單選。
/// 取代原 Material Dropdown 懸浮選單，消除在 iOS 上鍵盤與彈出覆蓋層的定位衝突。
class DegreeLevelField extends StatelessWidget {
  const DegreeLevelField({
    super.key,
    required this.selectedDegreeLevel,
    required this.onChanged,
  });

  final DEGREE_LEVEL selectedDegreeLevel;
  final ValueChanged<DEGREE_LEVEL> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '學制',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<DEGREE_LEVEL>(
            segments: [
              for (final level in DEGREE_LEVEL.values)
                ButtonSegment<DEGREE_LEVEL>(
                  value: level,
                  label: Text(degreeLevelLabel(level)),
                ),
            ],
            selected: {selectedDegreeLevel},
            emptySelectionAllowed: false,
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
            ),
            onSelectionChanged: (newSelection) {
              if (newSelection.isNotEmpty) {
                AppHaptics.selection();
                onChanged(newSelection.first);
              }
            },
          ),
        ),
      ],
    );
  }
}
