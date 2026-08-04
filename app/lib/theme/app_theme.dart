import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'platform_adaptive.dart';

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

  /// 退場比進場快（約 60–70%）——進場要讓人看清楚新東西從哪來，退場只要
  /// 「消失得不突兀」就好，拖一樣久會顯得鈍。
  static const exit = Duration(milliseconds: 160);

  /// iOS「減少動態效果」(設定 > 輔助使用 > 動態效果) 與 Android 的同類設定，
  /// Flutter 都會反映在 [MediaQueryData.disableAnimations] 上。這是 WCAG 與
  /// HIG 都列為必須遵守的項目——前庭系統敏感的使用者開了這個開關之後，
  /// 縮放／位移類動畫會造成實際不適，不是單純的偏好問題。
  ///
  /// 用法是把時長歸零而不是拆掉 widget：動畫結束狀態仍然是正確的 UI 狀態，
  /// 只是瞬間到位，呼叫端不需要為了無障礙寫第二套 build 分支。
  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : value;

  /// 「這個情境該不該做裝飾性動畫」的單一判斷點——用於進場交錯、shimmer
  /// 這類純粹為了觀感存在、拿掉也不影響理解的效果。
  static bool allowsDecorative(BuildContext context) =>
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

abstract final class AppTheme {
  static ThemeData light = _build(Brightness.light);
  static ThemeData dark = _build(Brightness.dark);

  /// 字級系統。這支 App 原本完全沒動過 `textTheme`，直接吃 Material 預設值
  /// ——那套數值是為**拉丁字母**調的，套在中文介面上有兩個具體問題：
  ///
  /// 1. **行高太擠。** Material 的 `bodyMedium` 行高約 1.43，拉丁小寫字母有
  ///    大量視覺留白（x-height 以上/以下都是空的），中文是滿版方塊字，同樣
  ///    行高看起來會明顯黏在一起。長段落（活動說明、使用說明、錯誤訊息）拉到
  ///    1.5–1.6 才有呼吸感。
  /// 2. **字距是負分。** Material 給 body 系列 `letterSpacing: 0.25~0.5`，用意
  ///    是拉開拉丁字母；中文每個字本來就是等寬方塊，再加字距只會讓詞的邊界
  ///    變模糊、讀起來鬆散。中文排版正確做法是 0。
  ///
  /// 這裡刻意**不指定 `fontFamily`**：[ThemeData] 會把這份 theme 合併到平台
  /// 預設字體上，iOS 因此保留 SF Pro、Android 保留 Roboto。指定字體會直接
  /// 毀掉 iOS 的原生感——SF Pro 是 iOS「看起來像 iOS」最大的單一因素，而
  /// 中文字型在兩個平台上也各自由系統挑選（蘋方 / 思源黑體），硬指定反而錯。
  static TextTheme _textTheme() {
    // 標題群：收緊行高、字重加到 w600/w700 建立層級（guideline:
    // weight-hierarchy——用字重而不是只用字級拉開層次）。
    const heading = TextStyle(height: 1.3, letterSpacing: 0, fontWeight: FontWeight.w700);
    const title = TextStyle(height: 1.35, letterSpacing: 0, fontWeight: FontWeight.w600);
    // 內文群：行高 1.55（落在 guideline 建議的 1.5–1.75 內、偏保守端，
    // 因為卡片式版面段落都很短，拉太開反而散）。
    const body = TextStyle(height: 1.55, letterSpacing: 0);
    // 標籤群：狀態晶片、按鈕文字這類短字串，行高不需要那麼鬆，
    // 字重 w500 讓它在卡片裡站得住。
    const label = TextStyle(height: 1.3, letterSpacing: 0, fontWeight: FontWeight.w500);

    return const TextTheme(
      displayLarge: heading,
      displayMedium: heading,
      displaySmall: heading,
      headlineLarge: heading,
      headlineMedium: heading,
      headlineSmall: heading,
      titleLarge: title,
      titleMedium: title,
      titleSmall: title,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: body,
      labelLarge: label,
      labelMedium: label,
      labelSmall: label,
    );
  }

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
      textTheme: _textTheme(),
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      // iOS HIG：標題置中、44pt 高度、無 Material 3 的 tonal 上色（surfaceTint）
      // ——那個「往下捲動就整條變色」的效果是 Material 特有語言，套用在 iOS
      // 上反而不像原生導覽列。Android 維持原本靠左標題＋捲動變色。
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: isCupertino ? 0 : 1,
        surfaceTintColor: isCupertino ? Colors.transparent : null,
        centerTitle: isCupertino,
        toolbarHeight: isCupertino ? 44 : null,
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
