import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A single condition displayed in an [AppSelectionSummary].
class AppSelectionSummaryItem {
  const AppSelectionSummaryItem({required this.label, required this.value});

  final String label;
  final String value;
}

/// An accessible overview of the criteria selected for a match.
class AppSelectionSummary extends StatelessWidget {
  const AppSelectionSummary({
    super.key,
    required this.items,
    this.expanded = true,
  });

  final List<AppSelectionSummaryItem> items;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.extension<AppSurfaceColors>()!;
    final semanticsLabel = '配對條件摘要，${expanded ? '已展開' : '已收合'}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: surface.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            container: true,
            excludeSemantics: true,
            label: semanticsLabel,
            expanded: expanded,
            child: Text('配對條件摘要', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: AppSpacing.sm),
          expanded ? _expandedItems(theme) : _collapsedItems(theme),
        ],
      ),
    );
  }

  Widget _expandedItems(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          _item(theme, items[index]),
          if (index < items.length - 1) const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }

  Widget _collapsedItems(ThemeData theme) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final item in items)
          Semantics(
            container: true,
            excludeSemantics: true,
            label: '${item.label}：${item.value}',
            child: Chip(label: Text('${item.label}：${item.value}')),
          ),
      ],
    );
  }

  Widget _item(ThemeData theme, AppSelectionSummaryItem item) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${item.label}：${item.value}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(item.value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
