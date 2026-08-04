import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 骨架屏（skeleton / shimmer）——取代清單類內容原本置中的轉圈圈。
///
/// 差別不只是好看：置中轉圈圈會讓畫面在「空白 → 有內容」之間整個跳一次
/// （版面位移），而且沒有傳達「即將出現什麼形狀的東西」。骨架屏先把版面
/// 撐在正確的位置，資料到位時只是填色，感知等待時間明顯較短。HIG 也直接
/// 建議超過 1 秒的載入用 placeholder content 而不是 spinner。
///
/// 這裡刻意不引入 `shimmer` 之類的套件——效果只是一條漸層掃過去，
/// 用 [AnimatedBuilder] + [ShaderMask] 二十行就夠，不值得多一個相依。
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = AppRadius.sm,
  });

  /// `null` 表示撐滿可用寬度。
  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHigh;
    final highlight = Color.lerp(base, scheme.onSurface, 0.06)!;

    final block = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );

    // 開了「減少動態效果」就只留靜態色塊：掃光是純裝飾，拿掉不影響「這裡
    // 正在載入」的訊息傳達（形狀本身就是訊息）。
    if (!AppMotion.allowsDecorative(context)) return block;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            // -1 → 2 讓漸層完整掃出畫面兩側，避免在邊緣「停一下」再跳回。
            final dx = bounds.width * (_controller.value * 3 - 1);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(Rect.fromLTWH(dx, 0, bounds.width, bounds.height));
          },
          child: child,
        );
      },
      child: block,
    );
  }
}

/// 「我的活動」卡片形狀的骨架——刻意複製 `_ActivityCard` 的骨架（44pt 方形
/// icon 色塊 + 右側三行文字），讓資料到位時的形狀變化最小。
class ActivityCardSkeleton extends StatelessWidget {
  const ActivityCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Skeleton(width: 44, height: 44),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: 120, height: 14),
                SizedBox(height: 10),
                Skeleton(width: 160, height: 11),
                SizedBox(height: 6),
                Skeleton(width: 100, height: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 幾張卡片骨架疊起來的清單佔位。數量固定 3 張——夠撐出「這是一個清單」的
/// 形狀，又不會在真實資料只有 1 筆時讓畫面塌陷得太明顯。
class ActivityListSkeleton extends StatelessWidget {
  const ActivityListSkeleton({super.key, this.itemCount = 3});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, _) => const ActivityCardSkeleton(),
    );
  }
}
