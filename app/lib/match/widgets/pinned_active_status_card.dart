import 'package:flutter/material.dart';

import '../../generated/activity.dart';
import '../../generated/match_request.dart';
import '../../generated/supadart_header.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

/// 置頂進行中狀態卡（v1.43）
///
/// 取代舊版「已有 request 或 activity 時整頁改成不可互動的阻擋卡」——
/// 當使用者已在等待室（REQUESTING / PENDING_CONFIRMATION）或已有活動時，
/// 在首頁頂端置頂呈現這張狀態卡，引導回等待室或活動房間，
/// 但依然保留下方探索區域，讓使用者可隨時看見校園即時需求動態。
class PinnedActiveStatusCard extends StatelessWidget {
  const PinnedActiveStatusCard({
    super.key,
    required this.request,
    required this.activity,
    this.onOpenWaitingRoom,
    this.onOpenActivity,
  });

  final MatchRequest? request;
  final Activity? activity;
  final VoidCallback? onOpenWaitingRoom;
  final VoidCallback? onOpenActivity;

  @override
  Widget build(BuildContext context) {
    if (request == null && activity == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final isActivity = activity != null;
    final title = isActivity ? '你目前有進行中的活動' : '你正在配對中';
    final statusLabel = isActivity
        ? (activity!.status == ACTIVITY_STATUS.ONGOING
            ? '活動進行中'
            : '已成團，等待出發')
        : (request!.status == REQUEST_STATUS.PENDING_CONFIRMATION
            ? '小人數確認中'
            : '等待配對中');

    final actionLabel = isActivity ? '前往活動房間' : '前往等待室';
    final onAction = isActivity ? onOpenActivity : onOpenWaitingRoom;
    final icon = isActivity
        ? Icons.celebration_rounded
        : Icons.hourglass_top_rounded;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '狀態：$statusLabel · 已為你保留名額',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '進行中期間暫無法送出新配對，但可隨時瀏覽校園動態。',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                label: actionLabel,
                icon: Icons.arrow_forward_rounded,
                onPressed: onAction,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
