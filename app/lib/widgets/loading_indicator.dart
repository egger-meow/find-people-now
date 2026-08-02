import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/platform_adaptive.dart';

/// 統一的載入態，取代裸的 CircularProgressIndicator 散落各處。
/// iOS 用 [CupertinoActivityIndicator]（原生轉圈點陣），Android 維持
/// Material [CircularProgressIndicator]——單一集中改點，呼叫端完全不用改。
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          isCupertino ? const CupertinoActivityIndicator(radius: 14) : const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
