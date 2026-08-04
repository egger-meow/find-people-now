import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';

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
///
/// 刻意仍然使用 Material [SnackBar] 而不是在 iOS 上換成別的東西：iOS 沒有
/// 對應的原生「短暫提示」元件（原生 App 多半自己刻），底部浮動膠囊在兩個
/// 平台上都不違和，而且 Flutter 的 SnackBar 本身就不搶焦點、符合
/// `toast-accessibility`（螢幕閱讀器會朗讀，但不會把焦點抓走）。
void showAppSnackBar(
  BuildContext context,
  String message, {
  AppSnackKind kind = AppSnackKind.neutral,
}) {
  final scheme = Theme.of(context).colorScheme;

  final (Color background, Color foreground, IconData? icon) = switch (kind) {
    AppSnackKind.success => (scheme.primaryContainer, scheme.onPrimaryContainer, Icons.check_circle_rounded),
    AppSnackKind.error => (scheme.errorContainer, scheme.onErrorContainer, Icons.error_rounded),
    AppSnackKind.neutral => (scheme.inverseSurface, scheme.onInverseSurface, null),
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
  // 連續操作時舊的提示還掛在畫面上，新的會排隊等前一則播完——使用者會看到
  // 一則明顯過期的訊息。直接換掉。
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: background,
      // guideline `toast-dismiss`：3–5 秒。錯誤給滿 5 秒（要讀懂發生什麼事、
      // 可能還要記下來），其餘 3 秒。
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
