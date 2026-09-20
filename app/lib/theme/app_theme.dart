import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'platform_adaptive.dart';

/// 品牌 DNA：🌿 Fresh／⚡ Instant／🤝 Human／🎓 Campus／☀️ Optimistic／🎯 Minimal。
/// 「校園裡有人正在做事，而你隨時可以加入。」— 清新綠為主色，天空藍/暖黃點綴，
/// Material 3 為底層，但外觀（圓角、留白、無陰影卡片）刻意不是 Flutter 預設樣子。
abstract final class AppColors {
  static const seedGreen = Color(0xFF10B981);
  static const skyBlue = Color(0xFF38BDF8);
  static const warmYellow = Color(0xFFFBBF24);

  /// 淺色模式：暖米白背景、森林翡翠綠主色、自然大地色調
  static const lightSurface = Color(0xFFFAF9F6);
  static const forestGreen = Color(0xFF059669);
  static const forestGreenContainer = Color(0xFFD1FAE5);
  static const forestGreenOnContainer = Color(0xFF065F46);
  static const lightSurfaceCard = Color(0xFFF3F0EA);
  static const lightOutline = Color(0xFFD8D3C8);

  /// 暗色模式：活力校園深色調（深邃暖炭黑底 ＋ 鮮活翡翠綠 + 明亮米白字）
  static const darkSurface = Color(0xFF131614);
  static const darkOnSurface = Color(0xFFF3F4F6);
  static const darkOnSurfaceVariant = Color(0xFFC7CDC9);
  static const darkOutline = Color(0xFF6B756F);
  static const darkOutlineVariant = Color(0xFF323A35);

  /// 活力翡翠校園綠（取代暗淡的鼠尾草綠，呈現更具能量與快樂感之氛圍）
  static const vibrantGreen = Color(0xFF10B981);
  static const vibrantGreenOn = Color(0xFF022C22);
  static const vibrantGreenContainer = Color(0xFF064E3B);
  static const vibrantGreenOnContainer = Color(0xFFA7F3D0);

  // 向下相容別名
  static const sageGreen = vibrantGreen;
  static const sageGreenOn = vibrantGreenOn;
  static const sageGreenContainer = vibrantGreenContainer;
  static const sageGreenOnContainer = vibrantGreenOnContainer;
  static const accentGreen = vibrantGreen;
  static const accentGreenOn = vibrantGreenOn;
  static const accentGreenContainer = vibrantGreenContainer;
  static const accentGreenOnContainer = vibrantGreenOnContainer;
}


abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const glass = 28.0;
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
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
      ? Duration.zero
      : value;

  /// 「這個情境該不該做裝飾性動畫」的單一判斷點——用於進場交錯、shimmer
  /// 這類純粹為了觀感存在、拿掉也不影響理解的效果。
  static bool allowsDecorative(BuildContext context) =>
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// Calm-glass surfaces use semantic colors so screens never need to carry
/// their own translucency, borders, or ambient background colors.
class AppSurfaceColors extends ThemeExtension<AppSurfaceColors> {
  const AppSurfaceColors({
    required this.glass,
    required this.glassBorder,
    required this.hairline,
    required this.ambientStart,
    required this.ambientEnd,
  });

  static const light = AppSurfaceColors(
    glass: Color(0xF2FAF9F6),
    glassBorder: Color(0x1F726F68),
    hairline: Color(0x14000000),
    ambientStart: Color(0xFFE6F4EA),
    ambientEnd: Color(0xFFEDF6F2),
  );

  static const dark = AppSurfaceColors(
    glass: Color(0xF2161A17),
    glassBorder: Color(0x33FFFFFF),
    hairline: Color(0x24FFFFFF),
    ambientStart: Color(0xFF142B1F),
    ambientEnd: Color(0xFF12242C),
  );


  final Color glass;
  final Color glassBorder;
  final Color hairline;
  final Color ambientStart;
  final Color ambientEnd;

  @override
  AppSurfaceColors copyWith({
    Color? glass,
    Color? glassBorder,
    Color? hairline,
    Color? ambientStart,
    Color? ambientEnd,
  }) {
    return AppSurfaceColors(
      glass: glass ?? this.glass,
      glassBorder: glassBorder ?? this.glassBorder,
      hairline: hairline ?? this.hairline,
      ambientStart: ambientStart ?? this.ambientStart,
      ambientEnd: ambientEnd ?? this.ambientEnd,
    );
  }

  @override
  AppSurfaceColors lerp(covariant AppSurfaceColors? other, double t) {
    if (other == null) return this;
    return AppSurfaceColors(
      glass: Color.lerp(glass, other.glass, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      ambientStart: Color.lerp(ambientStart, other.ambientStart, t)!,
      ambientEnd: Color.lerp(ambientEnd, other.ambientEnd, t)!,
    );
  }
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
    const heading = TextStyle(
      height: 1.3,
      letterSpacing: 0,
      fontWeight: FontWeight.w700,
    );
    const title = TextStyle(
      height: 1.35,
      letterSpacing: 0,
      fontWeight: FontWeight.w600,
    );
    // 內文群：行高 1.55（落在 guideline 建議的 1.5–1.75 內、偏保守端，
    // 因為卡片式版面段落都很短，拉太開反而散）。
    const body = TextStyle(fontSize: 16, height: 1.55, letterSpacing: 0);
    // 標籤群：狀態晶片、按鈕文字這類短字串，行高不需要那麼鬆，
    // 字重 w500 讓它在卡片裡站得住。
    const label = TextStyle(
      height: 1.3,
      letterSpacing: 0,
      fontWeight: FontWeight.w500,
    );

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
    var scheme = ColorScheme.fromSeed(
      seedColor: brightness == Brightness.dark
          ? Colors.grey
          : AppColors.forestGreen,
      brightness: brightness,
      secondary: AppColors.skyBlue,
      tertiary: AppColors.warmYellow,
    );
    if (brightness == Brightness.light) {
      scheme = scheme.copyWith(
        surface: AppColors.lightSurface,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF7F5F0),
        surfaceContainer: const Color(0xFFF4F0EA),
        surfaceContainerHigh: AppColors.lightSurfaceCard,
        surfaceContainerHighest: const Color(0xFFEDE9E2),
        primary: AppColors.forestGreen,
        onPrimary: Colors.white,
        primaryContainer: AppColors.forestGreenContainer,
        onPrimaryContainer: AppColors.forestGreenOnContainer,
        outline: AppColors.lightOutline,
        outlineVariant: const Color(0xFFE5E0D6),
      );
    } else {
      scheme = scheme.copyWith(
        surface: AppColors.darkSurface,
        surfaceContainerLowest: const Color(0xFF0D100E),
        surfaceContainerLow: const Color(0xFF161A17),
        surfaceContainer: const Color(0xFF1C221E),
        surfaceContainerHigh: const Color(0xFF242C27),
        surfaceContainerHighest: const Color(0xFF2F3832),
        onSurface: AppColors.darkOnSurface,
        onSurfaceVariant: AppColors.darkOnSurfaceVariant,
        outline: AppColors.darkOutline,
        outlineVariant: AppColors.darkOutlineVariant,
        primary: AppColors.vibrantGreen,
        onPrimary: AppColors.vibrantGreenOn,
        primaryContainer: AppColors.vibrantGreenContainer,
        onPrimaryContainer: AppColors.vibrantGreenOnContainer,
        secondary: AppColors.skyBlue,
        secondaryContainer: const Color(0xFF0C4A6E),
        onSecondaryContainer: const Color(0xFFBAE6FD),
        tertiary: AppColors.warmYellow,
        tertiaryContainer: const Color(0xFF451A03),
        onTertiaryContainer: const Color(0xFFFDE68A),
      );
    }


    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: _textTheme(),
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      extensions: [
        brightness == Brightness.dark
            ? AppSurfaceColors.dark
            : AppSurfaceColors.light,
      ],
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
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
