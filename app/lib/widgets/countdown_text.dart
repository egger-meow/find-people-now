import 'dart:async';

import 'package:flutter/material.dart';

/// 依 [deadline] 動態算剩餘時間的倒數文字（如 `latest_start`／
/// `confirm_window_expire_at`）——UI_PLAN 明確要求「畫面不可寫死分鐘數」，
/// 一律從後端回傳的時間戳即時計算。過期後顯示 [expiredLabel]。
class CountdownText extends StatefulWidget {
  const CountdownText({
    super.key,
    required this.deadline,
    this.style,
    this.expiredLabel = '已逾時',
  });

  final DateTime deadline;
  final TextStyle? style;
  final String expiredLabel;

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

  @override
  Widget build(BuildContext context) {
    final remaining = widget.deadline.difference(DateTime.now());
    if (remaining.isNegative) {
      return Text(widget.expiredLabel, style: widget.style);
    }
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = remaining.inHours;
    final text = hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
    return Text(text, style: widget.style);
  }
}
