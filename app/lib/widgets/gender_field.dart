import 'package:flutter/material.dart';

import '../data/gender_options.dart';
import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';

/// 性別選擇元件：以受控的 SegmentedButton 提供「男 / 女 / 其他」單選。
/// 支援反悔取消（點選已選中項目可清除為 null），支援外部歷史字串的自動正規化。
class GenderField extends StatelessWidget {
  const GenderField({
    super.key,
    required this.selectedGender,
    required this.onChanged,
  });

  final String? selectedGender;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final normalized = GenderOptions.normalize(selectedGender);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '性別',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '選填，供展示與未來同性活動篩選',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: GenderOptions.male,
                label: Text('男'),
                icon: Icon(Icons.male_rounded, size: 18),
              ),
              ButtonSegment(
                value: GenderOptions.female,
                label: Text('女'),
                icon: Icon(Icons.female_rounded, size: 18),
              ),
              ButtonSegment(
                value: GenderOptions.other,
                label: Text('其他'),
                icon: Icon(Icons.transgender_rounded, size: 18),
              ),
            ],
            selected: normalized != null ? {normalized} : <String>{},
            emptySelectionAllowed: true,
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
              AppHaptics.selection();
              onChanged(newSelection.isEmpty ? null : newSelection.first);
            },
          ),
        ),
      ],
    );
  }
}
