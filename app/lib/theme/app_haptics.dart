import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 觸覺回饋的單一集中點。
///
/// 這支 App 原本一次 [HapticFeedback] 都沒呼叫過——在 Android 上不太明顯，
/// 但在 iOS 上「按了沒有震一下」是最直接的「這不是原生 App」訊號：iOS 使用者
/// 對 Taptic Engine 的期待已經內建在肌肉記憶裡（切分頁、選晶片、送出成功、
/// 出錯各有不同的手感）。這裡不直接在各畫面散呼叫 `HapticFeedback.xxx`，
/// 原因跟 [LoadingIndicator]／[AppAdaptiveDialog] 一樣：呼叫端只描述**語意**
/// （這是一次選取／這是一次成功／這是一次錯誤），實際震動強度是單一改點，
/// 之後要整體調弱或針對平台微調都不用掃全專案。
///
/// HIG 明確要求「重要動作與確認才給觸覺，不要濫用」，所以這裡刻意**沒有**
/// 提供泛用的 `vibrate()`：每個方法都對應一種語意場景，用錯會很明顯。
///
/// 平台差異：
/// - iOS：`selectionClick` → `UISelectionFeedbackGenerator`、`*Impact` →
///   `UIImpactFeedbackGenerator`，正是原生 App 的手感來源。
/// - Android：對應到 `HapticFeedbackConstants`，強度差異比 iOS 小，但語意仍
///   成立，因此不特別分岔。
/// - Web：平台通道沒有實作，呼叫只會白費一次 channel round-trip，直接擋掉。
abstract final class AppHaptics {
  /// 選取類：切換分頁、選晶片、切分段控制、改選項。
  /// 最輕的一種——這類操作頻率高，用重的會變成噪音。
  static void selection() {
    if (kIsWeb) return;
    HapticFeedback.selectionClick();
  }

  /// [selection] 的 callback 包裝版，給 `onSelected:` 這種
  /// `ValueChanged<T>` 欄位用——讓呼叫端維持單行 arrow 寫法，不必為了插一行
  /// 觸覺就把 `(_) => setState(...)` 展開成區塊。
  ///
  /// 用法：`onSelected: AppHaptics.select((_) => setState(...))`
  static ValueChanged<T> select<T>(ValueChanged<T> action) => (value) {
        selection();
        action(value);
      };

  /// 一般點擊：主要按鈕按下的當下（不是完成之後）。
  /// 跟 [AppButton] 的縮放動畫同時發生，讓「按下去了」這件事同時有視覺跟觸覺。
  static void tap() {
    if (kIsWeb) return;
    HapticFeedback.lightImpact();
  }

  /// 成功：送出配對成功、成團、加入房間、完成確認。
  /// 比 [tap] 重一階，讓「事情真的發生了」跟「我按到按鈕了」在手感上可區分。
  static void success() {
    if (kIsWeb) return;
    HapticFeedback.mediumImpact();
  }

  /// 警告／破壞性操作即將發生：取消配對、退出房間、封鎖、刪除帳號。
  static void warning() {
    if (kIsWeb) return;
    HapticFeedback.mediumImpact();
  }

  /// 錯誤：RPC 失敗、驗證不通過。
  /// 最重的一種——錯誤本來就該打斷使用者的節奏。
  static void error() {
    if (kIsWeb) return;
    HapticFeedback.heavyImpact();
  }
}
