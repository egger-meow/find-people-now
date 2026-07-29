import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 品牌 DNA：🌿 Fresh／⚡ Instant／🤝 Human／🎓 Campus／☀️ Optimistic／🎯 Minimal。
/// 「校園裡有人正在做事，而你隨時可以加入。」— 清新綠為主色，天空藍/暖黃點綴，
/// Material 3 為底層，但外觀（圓角、留白、無陰影卡片）刻意不是 Flutter 預設樣子。
abstract final class AppColors {
  static const seedGreen = Color(0xFF2FB380);
  static const skyBlue = Color(0xFF4FB8E8);
  static const warmYellow = Color(0xFFFFC94D);

  /// 反饋：黑底配原本的 [seedGreen]（偏霧的薄荷綠）在暗色模式下「很醜/噁心」，
  /// 「黑色至少要搭螢光綠」。單純把 [neonGreen] 拿去當 `ColorScheme.fromSeed`
  /// 的 seed 沒用——M3 的 tonal palette 演算法對暗色 scheme 的 primary 一律
  /// 收斂到偏淡、偏灰的高 tone 值（約 tone 80），不管 seed 多飽和，算出來的
  /// primary 幾乎都長得差不多（試過，兩者色票視覺上幾乎沒差）。要真的螢光，
  /// 必須繞過 tonal 演算法，直接把這個色值蓋回 `colorScheme.primary`（見下方
  /// `_build`），不能只調 seed。淺色模式維持原本品牌綠，沒人反應那邊有問題。
  static const neonGreen = Color(0xFF39FF14);
  static const neonGreenOn = Color(0xFF041B0A);
}

abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const pill = 999.0;
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// 短、自然、有回饋——不是滿天飛特效，是互動節奏的統一參數。
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 250);
  static const curve = Curves.easeOutCubic;
}

abstract final class AppTheme {
  static ThemeData light = _build(Brightness.light);
  static ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    var scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seedGreen,
      brightness: brightness,
      secondary: AppColors.skyBlue,
      tertiary: AppColors.warmYellow,
    );
    if (brightness == Brightness.dark) {
      // 直接蓋掉 tonal 演算法算出來的 primary/primaryContainer，換成真正
      // 飽和的螢光綠——見上面 [AppColors.neonGreen] 的註解，這是唯一能讓
      // 暗色模式主色實際「亮」起來的做法。
      scheme = scheme.copyWith(
        primary: AppColors.neonGreen,
        onPrimary: AppColors.neonGreenOn,
        primaryContainer: AppColors.neonGreen,
        onPrimaryContainer: AppColors.neonGreenOn,
      );
    }

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        side: BorderSide.none,
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
