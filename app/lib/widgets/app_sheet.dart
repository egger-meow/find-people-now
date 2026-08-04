import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';

/// 底部彈出面板的統一入口，取代各處裸呼叫的 `showModalBottomSheet(...)`。
///
/// 原本五個呼叫點都只傳了 `context` / `isScrollControlled` / `builder`，其餘
/// 全吃 Flutter 預設值，因此少了三件在 iOS 上很明顯的事：
///
/// 1. **沒有 `useSafeArea`。** 預設 `false`，`isScrollControlled: true` 的高面板
///    會一路延伸到螢幕最頂端——內容直接跑到瀏海／Dynamic Island 底下。這是
///    實際會遮住文字的版面錯誤，不只是美觀問題。
/// 2. **沒有拖曳握把（grabber）。** iOS 原生 sheet 頂端那條小橫槓是「可以往下
///    拉關掉」的可見提示。Flutter 有內建（`showDragHandle`），但預設關閉，
///    等於把關閉方式藏起來只留手勢——違反 guideline `modal-escape`／
///    `gesture-alternative`（重要操作不能只有手勢入口）。
/// 3. **圓角是 Material 尺度。** iOS sheet 的頂端圓角明顯更大，用 [AppRadius.lg]
///    對齊，跟 Material 分支各自維持自己的視覺語言。
///
/// 另外補上開啟時的輕觸覺——iOS 原生 sheet 彈出有實體感，沒有回饋會覺得
/// 畫面「浮」出來但手上沒感覺。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
}) {
  AppHaptics.selection();
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    // 面板內容自己不再需要包 SafeArea，交給這裡統一處理上下兩端
    // （頂端避開瀏海、底端避開 home indicator）。
    useSafeArea: true,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(isCupertino ? AppRadius.lg : AppRadius.md),
      ),
    ),
    builder: builder,
  );
}
