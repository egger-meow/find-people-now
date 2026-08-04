import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';

/// 品牌卡片：無陰影、扁平色塊 + 圓角，符合「Minimal 但不冷淡」——用色塊區分
/// 層次，不靠陰影堆疊。
///
/// 可點擊時的按壓回饋依平台分岔，理由跟 [AppAdaptiveDialog]／[LoadingIndicator]
/// 同一條：Material 的墨水漣漪（[InkWell]）是 Android 的視覺語言，從卡片被點
/// 的位置擴散出去；iOS 沒有這個概念，原生列表/卡片的按壓是**整塊短暫壓下並
/// 變暗**。在 iOS 上放漣漪是那種說不出哪裡怪、但一看就知道是跨平台框架做的
/// 破綻，所以 iOS 走 [_CupertinoPressable]（縮放＋透明度），Android 維持漣漪。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// 卡片內容通常是好幾段文字拼起來的（類型／時間／地點／狀態），VoiceOver
  /// 預設會一段一段唸、聽起來很零碎。有給這個值時就整張卡片合併成一個可點
  /// 的語意節點，唸出一句完整的描述。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: child,
    );

    if (onTap == null) return content;

    final Widget tappable = isCupertino
        ? _CupertinoPressable(onTap: onTap!, child: content)
        : Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: InkWell(
              onTap: () {
                AppHaptics.selection();
                onTap!();
              },
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: content,
            ),
          );

    if (semanticLabel == null) return tappable;
    return Semantics(
      button: true,
      label: semanticLabel,
      // 底下那堆 Text 已經被上面這行概括了，再讓它們各自曝光就會唸兩次。
      child: ExcludeSemantics(child: tappable),
    );
  }
}

/// iOS 風格的整塊按壓回饋：按下時輕微縮小並變暗，放開彈回。
/// 縮放幅度刻意很小（0.98）——卡片面積大，跟按鈕用同樣的 0.97 會顯得晃動；
/// 同時用 [AnimatedScale] 而不是改變寬高，避免觸發 layout 重排（動的是
/// transform，不會讓相鄰卡片跟著位移）。
class _CupertinoPressable extends StatefulWidget {
  const _CupertinoPressable({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_CupertinoPressable> createState() => _CupertinoPressableState();
}

class _CupertinoPressableState extends State<_CupertinoPressable> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context, const Duration(milliseconds: 120));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        AppHaptics.selection();
        _set(true);
      },
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: duration,
        curve: AppMotion.curve,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.72 : 1,
          duration: duration,
          child: widget.child,
        ),
      ),
    );
  }
}
