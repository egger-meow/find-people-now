import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 品牌 DNA：🌿 Fresh／⚡ Instant／🤝 Human／🎓 Campus／☀️ Optimistic／🎯 Minimal。
/// 「校園裡有人正在做事，而你隨時可以加入。」— 清新綠為主色，天空藍/暖黃點綴，
/// Material 3 為底層，但外觀（圓角、留白、無陰影卡片）刻意不是 Flutter 預設樣子。
abstract final class AppColors {
  static const seedGreen = Color(0xFF2FB380);
  static const skyBlue = Color(0xFF4FB8E8);
  static const warmYellow = Color(0xFFFFC94D);

  /// 反饋 v2：黑底配螢光綠（[neonGreen]，已移除）被回報「像 terminal /
  /// crypto trading bot」，跟「校園找人」的產品語言不符。改成暖灰底＋米白字
  /// ＋收斂過的綠色點綴——保留品牌綠的識別度，但不再整頁螢光。
  ///
  /// 暗色 surface 系列刻意手動指定、不用 `ColorScheme.fromSeed` 算出來的值：
  /// fromSeed 的 surface tonal palette 跟著 seed 色相走，用綠色 seed 算出來的
  /// 暗色背景一定偏綠黑（這正是上一版「黑底也偏綠」的成因）。這裡改用中性灰
  /// seed 算主要 tonal 結構（outline/error 等未覆寫欄位），再手動蓋上
  /// surface／primary 家族，兩邊互不干擾。
  static const darkSurface = Color(0xFF121212);
  static const darkOnSurface = Color(0xFFF2EFEA);
  static const darkOnSurfaceVariant = Color(0xFFC9C4BC);
  static const darkOutline = Color(0xFF8A857D);
  static const darkOutlineVariant = Color(0xFF3A3834);

  /// 收斂過的綠（沿用反饋建議的 #7CFF6B）——比原本螢光綠 (#39FF14) 深、飽和
  /// 度降一階，當 accent 用還是一眼可辨，但不會整片刺眼。
  static const accentGreen = Color(0xFF7CFF6B);
  static const accentGreenOn = Color(0xFF0C2B0C);
  static const accentGreenContainer = Color(0xFF1E3B1D);
  static const accentGreenOnContainer = Color(0xFFB7F0B4);
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
    // 暗色模式的 tonal 結構改用中性灰 seed 算（outline/error 等沒手動覆寫的
    // 欄位才不會沾到綠色調）；亮色模式維持原本品牌綠 seed，沒人反應那邊有
    // 問題，不動它。
    var scheme = ColorScheme.fromSeed(
      seedColor: brightness == Brightness.dark ? Colors.grey : AppColors.seedGreen,
      brightness: brightness,
      secondary: AppColors.skyBlue,
      tertiary: AppColors.warmYellow,
    );
    if (brightness == Brightness.dark) {
      scheme = scheme.copyWith(
        surface: AppColors.darkSurface,
        surfaceContainerLowest: Color.lerp(AppColors.darkSurface, Colors.black, 0.35),
        surfaceContainerLow: Color.lerp(AppColors.darkSurface, Colors.white, 0.03),
        surfaceContainer: Color.lerp(AppColors.darkSurface, Colors.white, 0.05),
        surfaceContainerHigh: Color.lerp(AppColors.darkSurface, Colors.white, 0.08),
        surfaceContainerHighest: Color.lerp(AppColors.darkSurface, Colors.white, 0.12),
        onSurface: AppColors.darkOnSurface,
        onSurfaceVariant: AppColors.darkOnSurfaceVariant,
        outline: AppColors.darkOutline,
        outlineVariant: AppColors.darkOutlineVariant,
        primary: AppColors.accentGreen,
        onPrimary: AppColors.accentGreenOn,
        primaryContainer: AppColors.accentGreenContainer,
        onPrimaryContainer: AppColors.accentGreenOnContainer,
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
