import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_haptics.dart';
import '../theme/platform_adaptive.dart';

/// 下拉重新整理的平台分岔。
///
/// 原本四個畫面都直接用 Material 的 [RefreshIndicator]——那顆從頂端浮下來的
/// 圓形進度環是 Android 的視覺語言。iOS 沒有這個元件，原生的下拉更新是列表
/// **跟著手指彈性拉開**、露出漸進顯示的活動指示器（[CupertinoSliverRefreshControl]），
/// 而且是 sliver、跟捲動位移連動，不是疊在內容上的浮層。在 iOS 上放 Material
/// 那顆環，是使用者第一眼就會覺得「這不是 iOS App」的地方之一。
///
/// API 收成 sliver 形式（而不是包一個現成的 [ListView]）是被
/// [CupertinoSliverRefreshControl] 的本質決定的：它必須跟內容在同一個
/// [CustomScrollView] 的 sliver 串列裡，才能讀到捲動 offset 做彈性拉伸。包一層
/// ListView 就拿不到那個 offset，只能退回浮層做法，等於白做。呼叫端因此要把
/// 內容改寫成 sliver（[SliverList]／[SliverToBoxAdapter]／[SliverFillRemaining]），
/// 這是一次性的成本，換到的是兩個平台各自正確的手感。
class AdaptiveRefresh extends StatelessWidget {
  const AdaptiveRefresh({super.key, required this.onRefresh, required this.slivers});

  final Future<void> Function() onRefresh;
  final List<Widget> slivers;

  Future<void> _handleRefresh() async {
    // iOS 原生下拉更新在觸發門檻時會震一下，告訴使用者「放手就會更新」。
    // [CupertinoSliverRefreshControl] 本身不做觸覺，要自己補。
    AppHaptics.tap();
    await onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final scrollView = CustomScrollView(
      // 內容不滿一頁時預設不可捲動，下拉手勢就完全收不到——兩個平台的下拉
      // 更新都會因此在空清單／短清單上失效，而「空清單想重新抓一次」正是最
      // 需要下拉更新的情境。
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (isCupertino) CupertinoSliverRefreshControl(onRefresh: _handleRefresh),
        ...slivers,
      ],
    );

    if (isCupertino) return scrollView;
    return RefreshIndicator(onRefresh: _handleRefresh, child: scrollView);
  }
}
