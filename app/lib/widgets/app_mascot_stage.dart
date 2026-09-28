import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 吉祥物街街貓的舞台風格
enum AppMascotStageStyle {
  /// 登入/註冊/首頁等主要迎賓 Hero 舞台：層次光暈、翡翠綠與暖陽黃微光、地面陰影
  hero,

  /// 卡片內空狀態／活動探索空狀態：圓形柔和舞台、精緻輪廓、地面陰影
  card,

  /// 等待配對中：律動呼吸光暈、安心等待氛圍
  waiting,

  /// 配對成功／慶祝狀態：歡慶金黃與活力綠光環
  celebration,

  /// 錯誤狀態／異常警告：柔和紅橙色警示光盤
  alert,

  /// 精簡圓形頭像／小卡片嵌入
  compact,
}

/// 街街貓（Mascot）專屬整合舞台組件
///
/// 徹底解決「角色圖片像被生硬貼在空白畫面上、與 UI 缺乏整體感」的問題。
/// 透過環境光暈（Aura Halo）、物理基座陰影（Grounding Pedestal）、
/// 以及校園品牌色系階層，讓街街貓與背景、文字及表單自然融合為一體。
class AppMascotStage extends StatelessWidget {
  const AppMascotStage({
    super.key,
    required this.assetPath,
    this.height = 140,
    this.semanticLabel,
    this.style = AppMascotStageStyle.card,
    this.showGroundShadow = true,
    this.badge,
    this.onTap,
  });

  /// 吉祥物圖片資源路徑
  final String assetPath;

  /// 吉祥物本身的高度（舞台會依此等比縮放背景與陰影）
  final double height;

  /// 螢幕報讀語意文字
  final String? semanticLabel;

  /// 舞台呈現風格
  final AppMascotStageStyle style;

  /// 是否顯示角色站立／坐臥的物理地面微陰影
  final bool showGroundShadow;

  /// 舞台右上角或底部疊加的標籤徽章（例如步數標籤、狀態圖示）
  final Widget? badge;

  /// 點擊互動（若有）
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;

    // 計算各風格背景光盤尺寸與色彩
    final stageSize = height * 1.18;
    final shadowWidth = height * 0.75;

    Widget content = SizedBox(
      height: height + (showGroundShadow ? 18 : 6),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // 1. 環境光暈與背景舞台基底
          _buildBackdrop(context, stageSize, isDark, scheme),

          // 2. 地面物理陰影（將角色穩穩錨定在介面上，消除「在空中漂浮的貼圖感」）
          if (showGroundShadow)
            Positioned(
              bottom: 2,
              child: _buildGroundShadow(shadowWidth, isDark),
            ),

          // 3. 街街貓角色本體
          Positioned(
            bottom: showGroundShadow ? 6 : 0,
            child: Semantics(
              label: semanticLabel ?? '街街貓吉祥物',
              image: true,
              child: Image.asset(
                assetPath,
                height: height,
                fit: BoxFit.contain,
              ),
            ),
          ),

          // 4. 浮動標籤／角標徽章
          if (badge != null)
            Positioned(
              top: 0,
              right: 0,
              child: badge!,
            ),
        ],
      ),
    );

    if (onTap != null) {
      content = GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }

    return content;
  }

  /// 物理微陰影（柔和放射性漸層，使角色有落腳點）
  Widget _buildGroundShadow(double width, bool isDark) {
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.35)
        : const Color(0xFF1E293B).withValues(alpha: 0.12);

    return Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: RadialGradient(
          colors: [
            shadowColor,
            shadowColor.withValues(alpha: shadowColor.a * 0.3),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }

  /// 背景光盤與環境光暈
  Widget _buildBackdrop(
    BuildContext context,
    double size,
    bool isDark,
    ColorScheme scheme,
  ) {
    switch (style) {
      case AppMascotStageStyle.hero:
        return _HeroBackdrop(size: size, isDark: isDark);

      case AppMascotStageStyle.waiting:
        return _WaitingBackdrop(size: size, isDark: isDark);

      case AppMascotStageStyle.celebration:
        return _CelebrationBackdrop(size: size, isDark: isDark);

      case AppMascotStageStyle.alert:
        return _AlertBackdrop(size: size, isDark: isDark, scheme: scheme);

      case AppMascotStageStyle.compact:
        return Container(
          width: size * 0.85,
          height: size * 0.85,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surfaceContainerHighest.withValues(
              alpha: isDark ? 0.4 : 0.6,
            ),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
        );

      case AppMascotStageStyle.card:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                scheme.primaryContainer.withValues(alpha: isDark ? 0.3 : 0.45),
                scheme.surfaceContainerHighest.withValues(
                  alpha: isDark ? 0.15 : 0.25,
                ),
                Colors.transparent,
              ],
              stops: const [0.2, 0.75, 1.0],
            ),
            border: Border.all(
              color: scheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
              width: 1.2,
            ),
          ),
        );
    }
  }
}

/// Hero 迎賓大舞台：翡翠綠 + 暖陽黃雙重環境柔光與精緻微光同心圈
class _HeroBackdrop extends StatelessWidget {
  const _HeroBackdrop({required this.size, required this.isDark});

  final double size;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final emeraldTone = AppColors.vibrantGreen;
    final yellowTone = AppColors.warmYellow;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 外層超柔放射光暈（與畫面背景無縫融合）
          Container(
            width: size * 1.35,
            height: size * 1.35,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  emeraldTone.withValues(alpha: isDark ? 0.22 : 0.14),
                  yellowTone.withValues(alpha: isDark ? 0.12 : 0.08),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          // 內層實心微光台（提供透明角色輪廓良好的對比度）
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  (isDark ? const Color(0xFF1E2721) : const Color(0xFFEAF8F1))
                      .withValues(alpha: 0.85),
                  (isDark ? const Color(0xFF131A15) : const Color(0xFFF3FAF6))
                      .withValues(alpha: 0.5),
                ],
                stops: const [0.4, 1.0],
              ),
              border: Border.all(
                color: emeraldTone.withValues(alpha: isDark ? 0.35 : 0.22),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: emeraldTone.withValues(alpha: isDark ? 0.15 : 0.08),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          // 細膩的裝飾微光線條圈
          Container(
            width: size * 0.82,
            height: size * 0.82,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: yellowTone.withValues(alpha: isDark ? 0.25 : 0.18),
                width: 1.0,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 等待配對中舞台：帶有呼吸節奏的同心光波
class _WaitingBackdrop extends StatefulWidget {
  const _WaitingBackdrop({required this.size, required this.isDark});

  final double size;
  final bool isDark;

  @override
  State<_WaitingBackdrop> createState() => _WaitingBackdropState();
}

class _WaitingBackdropState extends State<_WaitingBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowMotion = AppMotion.allowsDecorative(context);
    final emerald = AppColors.vibrantGreen;
    final skyBlue = AppColors.skyBlue;

    if (!allowMotion) {
      return Container(
        width: widget.size * 1.1,
        height: widget.size * 1.1,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              emerald.withValues(alpha: widget.isDark ? 0.25 : 0.18),
              skyBlue.withValues(alpha: widget.isDark ? 0.12 : 0.08),
              Colors.transparent,
            ],
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = 1.0 + (_controller.value * 0.08);
        final opacity = 0.14 + (_controller.value * 0.12);

        return Stack(
          alignment: Alignment.center,
          children: [
            // 外層呼吸圈
            Transform.scale(
              scale: scale,
              child: Container(
                width: widget.size * 1.25,
                height: widget.size * 1.25,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      skyBlue.withValues(alpha: opacity),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // 內層基座圈
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    emerald.withValues(
                      alpha: widget.isDark ? 0.28 : 0.20,
                    ),
                    emerald.withValues(alpha: 0.05),
                  ],
                ),
                border: Border.all(
                  color: emerald.withValues(
                    alpha: widget.isDark ? 0.35 : 0.22,
                  ),
                  width: 1.4,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 配對成功慶祝舞台：黃金與翡翠耀眼光圈
class _CelebrationBackdrop extends StatelessWidget {
  const _CelebrationBackdrop({required this.size, required this.isDark});

  final double size;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final gold = AppColors.warmYellow;
    final emerald = AppColors.vibrantGreen;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 歡慶大光暈
          Container(
            width: size * 1.35,
            height: size * 1.35,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  gold.withValues(alpha: isDark ? 0.26 : 0.20),
                  emerald.withValues(alpha: isDark ? 0.18 : 0.12),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.6, 1.0],
              ),
            ),
          ),
          // 內層金碧圓盤
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  (isDark ? const Color(0xFF282516) : const Color(0xFFFEF9C3))
                      .withValues(alpha: 0.8),
                  (isDark ? const Color(0xFF1B231D) : const Color(0xFFECFDF5))
                      .withValues(alpha: 0.4),
                ],
              ),
              border: Border.all(
                color: gold.withValues(alpha: isDark ? 0.45 : 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: gold.withValues(alpha: isDark ? 0.20 : 0.14),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 警示／異常舞台：柔和紅橙色調光盤
class _AlertBackdrop extends StatelessWidget {
  const _AlertBackdrop({
    required this.size,
    required this.isDark,
    required this.scheme,
  });

  final double size;
  final bool isDark;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            scheme.errorContainer.withValues(alpha: isDark ? 0.35 : 0.4),
            scheme.errorContainer.withValues(alpha: 0.05),
          ],
          stops: const [0.4, 1.0],
        ),
        border: Border.all(
          color: scheme.error.withValues(alpha: isDark ? 0.35 : 0.22),
          width: 1.2,
        ),
      ),
    );
  }
}
