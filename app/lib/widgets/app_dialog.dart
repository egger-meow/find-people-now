import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/platform_adaptive.dart';

/// [AppAdaptiveDialog] 的單一動作按鈕描述——外觀（Cupertino
/// [CupertinoDialogAction] vs Material [TextButton]）由 dialog 本身決定，
/// 呼叫端只描述語意（文字／是否為破壞性操作／是否為預設動作）。
class AppDialogAction {
  const AppDialogAction({required this.label, required this.onPressed, this.isDestructive = false, this.isDefault = false});

  final String label;

  /// `null` 停用該按鈕（灰階、不可點）——跟原本 `TextButton(onPressed: null)`
  /// 的「送出中先擋掉」用法相容，Cupertino 的 [CupertinoDialogAction] 一樣支援
  /// `onPressed: null` 顯示停用態。
  final VoidCallback? onPressed;

  /// HIG：破壞性動作（刪除、封鎖、取消配對…）文字用紅色標示。
  final bool isDestructive;

  /// HIG：預設動作（通常是「確定」那個）用粗體標示。Cupertino 專用；
  /// Material 分支不需要，兩個按鈕視覺權重本來就一致。
  final bool isDefault;
}

/// 對話框外觀分岔（iOS 用 [CupertinoAlertDialog]／Android 用 Material
/// [AlertDialog]）——取代原本每個呼叫點各自手刻的 `AlertDialog(...)`。
/// `content` 維持任意 [Widget]，呼叫端若需要 [StatefulBuilder] 管理對話框
/// 內部互動狀態，一樣包在 `showDialog` 的 `builder` 裡、把這個 widget當
/// 最終回傳值即可，跟原本用法相容，不用重新設計互動邏輯。
class AppAdaptiveDialog extends StatelessWidget {
  const AppAdaptiveDialog({super.key, required this.title, this.content, required this.actions});

  final String title;
  final Widget? content;
  final List<AppDialogAction> actions;

  @override
  Widget build(BuildContext context) {
    if (isCupertino) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: content == null
            ? null
            : Padding(padding: const EdgeInsets.only(top: 8), child: DefaultTextStyle.merge(textAlign: TextAlign.center, child: content!)),
        actions: [
          for (final action in actions)
            CupertinoDialogAction(
              onPressed: action.onPressed,
              isDestructiveAction: action.isDestructive,
              isDefaultAction: action.isDefault,
              child: Text(action.label),
            ),
        ],
      );
    }
    return AlertDialog(
      title: Text(title),
      content: content,
      actions: [
        for (final action in actions)
          TextButton(
            onPressed: action.onPressed,
            style: action.isDestructive ? TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error) : null,
            child: Text(action.label),
          ),
      ],
    );
  }
}

/// 最常見的形狀——「標題 + 一段說明文字 + 取消/確定」——一行呼叫取代整段
/// `showDialog<bool>(... AlertDialog(...))` 樣板。回傳 `true` 表示使用者按了
/// 確定，`false`／對話框外點擊關閉都算取消。
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '確定',
  String cancelLabel = '取消',
  bool isDestructive = false,
  bool barrierDismissible = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => AppAdaptiveDialog(
      title: title,
      content: content ?? (message != null ? Text(message) : null),
      actions: [
        AppDialogAction(label: cancelLabel, onPressed: () => Navigator.of(dialogContext).pop(false)),
        AppDialogAction(
          label: confirmLabel,
          isDestructive: isDestructive,
          isDefault: !isDestructive,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  // 破壞性操作（取消配對、退出活動、封鎖、刪除帳號）被確認的當下給一次較重
  // 的觸覺——iOS 原生的刪除確認就是這個手感，作用是「這件事真的發生了」的
  // 生理層級確認，比事後才跳出來的提示更早到達。非破壞性的確認不給，
  // 否則每個「確定」都在震，回饋就失去意義（HIG：不要濫用）。
  if (isDestructive && (result ?? false)) AppHaptics.warning();
  return result ?? false;
}
