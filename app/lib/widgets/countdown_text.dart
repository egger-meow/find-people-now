import 'dart:async';

import 'package:flutter/material.dart';

/// 依 [deadline] 動態算剩餘時間的倒數文字（如 `latest_start`／
/// `confirm_window_expire_at`）——UI_PLAN 明確要求「畫面不可寫死分鐘數」，
/// 一律從後端回傳的時間戳即時計算。過期後顯示 [expiredLabel]。
///
/// [urgentColor] 是選填的緊急色——剩餘時間低於 [urgentThreshold] 時文字轉色
/// 並加上一個小時鐘 icon（不單靠顏色傳達急迫感）。預設不帶 [urgentColor]，
/// 行為跟原本完全一樣；只有真的「錯過會有後果」的倒數（等待室的配對截止、
/// 小人數安全確認的回應時限）才選擇性開啟。
class CountdownText extends StatefulWidget {
  const CountdownText({
    super.key,
    required this.deadline,
    this.style,
    this.expiredLabel = '已逾時',
    this.urgentColor,
    this.urgentThreshold = const Duration(minutes: 1),
  });

  final DateTime deadline;
  final TextStyle? style;
  final String expiredLabel;
  final Color? urgentColor;
  final Duration urgentThreshold;

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  /// 等寬數字（tabular figures）。這個 widget 每秒重繪一次，而多數字型的
  /// 比例數字（proportional figures）裡「1」比「8」窄——`00:11` 換到 `00:08`
  /// 整串文字的寬度就變了，倒數會一直左右抽動，旁邊的元素跟著被推。
  /// `tnum` 讓所有數字佔一樣寬，倒數就穩在原地。
  ///
  /// 用 [FontFeature] 而不是換成 monospace 字型：只改數字寬度，中文與標點
  /// 仍然用原本的系統字型（iOS 的 SF Pro 支援 `tnum`，Android 的 Roboto 也是）。
  TextStyle _withTabularFigures(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) {
    final remaining = widget.deadline.difference(DateTime.now());
    if (remaining.isNegative) {
      // 逾時文字是中文、不是數字，不需要等寬處理。
      return Text(widget.expiredLabel, style: widget.style);
    }
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = remaining.inHours;
    final text = hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';

    final urgentColor = widget.urgentColor;
    final isUrgent = urgentColor != null && remaining <= widget.urgentThreshold;
    if (!isUrgent) {
      return Text(text, style: _withTabularFigures(widget.style));
    }
    final urgentStyle = _withTabularFigures(widget.style).copyWith(
      color: urgentColor,
      fontWeight: FontWeight.bold,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_rounded, size: (urgentStyle.fontSize ?? 14) + 2, color: urgentColor),
        const SizedBox(width: 4),
        Text(text, style: urgentStyle),
      ],
    );
  }
}
