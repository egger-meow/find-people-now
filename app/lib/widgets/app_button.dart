import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
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
                    Text(widget.label),
                  ],
                ),
        ),
      ),
    );
  }
}
