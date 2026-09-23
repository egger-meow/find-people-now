import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';

/// 操作結果提示的語意分類。呼叫端說「這是成功／這是錯誤」，
/// 顏色、圖示、觸覺、停留時間由這裡統一決定。
enum AppSnackKind { neutral, success, error }

/// 統一的 SnackBar 出口，取代散在各處的
/// `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(...)))`。
///
/// 原本全 App 十幾個呼叫點都是**同一顆灰色 SnackBar**：送出成功、設定失敗、
/// 已複製邀請碼，長得一模一樣。使用者要把整句話讀完才知道剛剛那件事成功
/// 沒有——這正是 guideline `success-feedback`／`error-clarity` 要避免的情況：
/// 結果的**性質**應該在讀文字之前就傳達出去。
///
/// 這裡補三件事：
/// - **顏色 + 圖示**：錯誤用 `colorScheme.error` 系列、成功用主色系列。圖示是
///   必要的，不是裝飾——`color-not-only`：色盲使用者不能只靠紅／綠分辨結果。
/// - **觸覺**：成功一下中等、錯誤一下強震。手機通常在手上，觸覺比顏色更快到達。
/// - **停留時間**：錯誤訊息需要比「已複製」這種瑣事更久的閱讀時間。
/// - **iOS 浮動膠囊避讓**：iOS 上預設 floating 並浮在膠囊上方（iOS UX 指南 §8）。
void showAppSnackBar(
  BuildContext context,
  String message, {
  AppSnackKind kind = AppSnackKind.neutral,
}) {
  final scheme = Theme.of(context).colorScheme;

  final (Color background, Color foreground, IconData? icon) = switch (kind) {
    AppSnackKind.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_rounded
      ),
    AppSnackKind.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_rounded
      ),
    AppSnackKind.neutral => (
        scheme.inverseSurface,
        scheme.onInverseSurface,
        null
      ),
  };

  switch (kind) {
    case AppSnackKind.success:
      AppHaptics.success();
    case AppSnackKind.error:
      AppHaptics.error();
    case AppSnackKind.neutral:
      break;
  }

  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();

  final mediaQuery = MediaQuery.maybeOf(context);
  final isKeyboardOpen = (mediaQuery?.viewInsets.bottom ?? 0) > 0;
  final isIosFloating = isCupertino && !isKeyboardOpen;

  messenger.showSnackBar(
    SnackBar(
      behavior: isIosFloating ? SnackBarBehavior.floating : SnackBarBehavior.fixed,
      margin: isIosFloating
          ? EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              (mediaQuery?.padding.bottom ?? 0) + 76.0 + 8.0,
            )
          : null,
      shape: isIosFloating
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md))
          : null,
      backgroundColor: background,
      duration: Duration(seconds: kind == AppSnackKind.error ? 5 : 3),
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    ),
  );
}
