import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A consistently spaced section heading and content group.
class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    required this.title,
    this.description,
    required this.child,
    this.showDivider = false,
  });

  final String title;
  final String? description;
  final Widget child;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.extension<AppSurfaceColors>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        if (description != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            description!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (showDivider) ...[
          Divider(height: 1, color: surface.hairline),
          const SizedBox(height: AppSpacing.md),
        ],
        child,
      ],
    );
  }
}
