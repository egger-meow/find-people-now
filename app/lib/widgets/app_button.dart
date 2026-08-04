import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';

/// 主要行動按鈕（送出、確認參加…）。膠囊圓角 + 短暫按壓縮放回饋，
/// 呼應品牌關鍵字「Instant」「Calm Energy」——有回饋但不誇張。
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  double _scale = 1;

  void _setPressed(bool pressed) {
    setState(() => _scale = pressed ? 0.97 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    return GestureDetector(
      onTapDown: enabled
          ? (_) {
              // 觸覺跟縮放在同一個 frame 觸發——HIG 要求點擊回饋在 100ms 內
              // 送達，放到 onTap（手指抬起後）才震會慢半拍、感覺像延遲。
              AppHaptics.tap();
              _setPressed(true);
            }
          : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      child: AnimatedScale(
        scale: _scale,
        // 開了「減少動態效果」時歸零：按壓縮放屬於裝飾性動畫，但觸覺回饋仍然
        // 保留，使用者不會因此失去「我按到了」的確認。
        duration: AppMotion.duration(context, const Duration(milliseconds: 100)),
        child: FilledButton(
          onPressed: enabled ? widget.onPressed : null,
          child: widget.loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: isCupertino
                      ? CupertinoActivityIndicator(color: Theme.of(context).colorScheme.onPrimary)
                      : const CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, size: 20),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      // Dynamic Type 放到最大時，長標籤在膠囊按鈕裡會溢出。
                      // 允許換行（而不是截斷）——HIG 偏好 wrap over truncation，
                      // 按鈕高度由 `minimumSize` 撐開，不會擠壓旁邊的元素。
                      child: Text(widget.label, textAlign: TextAlign.center),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
