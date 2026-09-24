import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A sufficiently opaque, themed glass surface that remains legible before
/// the decorative backdrop blur is applied.
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry? borderRadius;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).extension<AppSurfaceColors>()!;
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.glass);
    final highContrast = MediaQuery.highContrastOf(context);
    final fill = highContrast
        ? Theme.of(context).colorScheme.surface
        : surface.glass;

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: Border.all(
          color: highContrast
              ? Theme.of(context).colorScheme.outline
              : surface.glassBorder,
        ),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
        child: child,
      ),
    );

    return ClipRRect(
      borderRadius: radius,
      child: highContrast
          ? content
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: content,
            ),
    );
  }
}
