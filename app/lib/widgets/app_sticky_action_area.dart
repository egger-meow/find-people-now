import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A bottom action container that keeps primary controls above both the
/// keyboard and the device safe area.
class AppStickyActionArea extends StatelessWidget {
  const AppStickyActionArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final surface = Theme.of(context).extension<AppSurfaceColors>()!;
    final bottomInset =
        mediaQuery.viewInsets.bottom + mediaQuery.padding.bottom;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.glass,
        border: Border(top: BorderSide(color: surface.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm + math.max(0, bottomInset),
        ),
        child: child,
      ),
    );
  }
}
