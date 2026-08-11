import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A calm, readable status block with optional leading content, deadline, and
/// action while preserving space for 200% Dynamic Type.
class AppStatusSummary extends StatelessWidget {
  const AppStatusSummary({
    super.key,
    required this.title,
    required this.message,
    this.leading,
    this.deadline,
    this.action,
    this.compact = false,
    this.inlineDeadline = false,
  });

  final String title;
  final String message;
  final Widget? leading;
  final String? deadline;
  final Widget? action;
  final bool compact;
  final bool inlineDeadline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.extension<AppSurfaceColors>()!;
    final showInlineDeadline = inlineDeadline && deadline != null;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? AppSpacing.sm : AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: surface.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                flex: showInlineDeadline ? 2 : 1,
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              if (showInlineDeadline) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: Text(
                    deadline!,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (deadline != null && !showInlineDeadline) ...[
            SizedBox(height: compact ? AppSpacing.xs : AppSpacing.sm),
            Text(
              deadline!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}
