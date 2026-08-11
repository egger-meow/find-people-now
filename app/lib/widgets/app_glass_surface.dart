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

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface.glass,
            borderRadius: radius,
            border: Border.all(color: surface.glassBorder),
          ),
          child: Padding(
            padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
            child: child,
          ),
        ),
      ),
    );
  }
}
