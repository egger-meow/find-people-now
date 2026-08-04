import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../generated/notification.dart' as generated;
import '../generated/supadart_header.dart' show NOTIFICATION_EVENT_TYPE;
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/skeleton.dart';
import 'notification_providers.dart';

/// UI_PLAN.md §5 通知——收件匣列表，未讀標記，點擊標已讀＋deep-link。
/// 文案照 §9「Notification 文案定案版」逐字對應，`{}` 佔位符從
/// `payload`（各事件實際 insert 的 jsonb_build_object 欄位，見對應 migration）
/// 動態代入。
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(notificationsStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: SafeArea(
        child: notificationsAsync.when(
          // 跟「我的活動」同一個理由：清單型內容用卡片骨架而不是置中轉圈圈。
          loading: () => const ActivityListSkeleton(itemCount: 4),
          error: (error, stack) => Center(child: Text('載入失敗：$error')),
          data: (notifications) {
            if (notifications.isEmpty) {
              final scheme = Theme.of(context).colorScheme;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_none_rounded, size: 40, color: scheme.onSurfaceVariant),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        '目前沒有通知\n配對成功、活動提醒都會出現在這裡',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: notifications.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) => _NotificationTile(notification: notifications[index]),
            );
          },
        ),
      ),
    );
  }
}

(String title, String body) _copyFor(generated.Notification n) {
  final payload = n.payload;
  String s(String key) => payload[key]?.toString() ?? '';

  return switch (n.eventType) {
    NOTIFICATION_EVENT_TYPE.MATCH_SUCCESS => ('配對成功！', '你的活動已經成團，點開看看誰要一起去'),
    NOTIFICATION_EVENT_TYPE.ACTIVITY_UPCOMING => ('活動快開始了', '還有 ${s('lead_minutes')} 分鐘，記得看一下活動地點跟集合地點'),
    NOTIFICATION_EVENT_TYPE.ACTIVITY_REMINDER => ('活動開始了', '時間到囉，記得看一下活動地點跟集合地點再出發'),
    NOTIFICATION_EVENT_TYPE.LOCATION_NOT_YET_PROPOSED => ('還沒選活動地點喔', '活動快開始了，還沒人提出活動地點，趕快去投一個吧'),
    NOTIFICATION_EVENT_TYPE.MEETING_POINT_UPDATED => ('集合地點更新了', '有人更新了集合地點：「${s('description')}」'),
    NOTIFICATION_EVENT_TYPE.COMPLETE_CONFIRMATION => ('活動結束了嗎？', '花 10 秒回報一下，這次有順利進行嗎？'),
    NOTIFICATION_EVENT_TYPE.DOWNGRADE_REQUEST =>
      ('有人數調整需要你同意', '目前人數不夠，是否同意降到 ${s('target_size')} 人成局？10 分鐘內沒回應視為不同意'),
    NOTIFICATION_EVENT_TYPE.DOWNGRADE_RESULT => s('status') == 'APPROVED'
        ? ('人數調整成立', '活動改成 ${s('target_size')} 人進行囉')
        : ('人數調整沒有成立', '活動維持原本的人數門檻，繼續幫你找人'),
    NOTIFICATION_EVENT_TYPE.MATCH_NOT_FORMED => ('這次配對沒有成立', '別擔心，可以重新發起新的邀約，我們會繼續幫你找人'),
    NOTIFICATION_EVENT_TYPE.MEMBER_ARRIVED => ('${s('display_name')} 已抵達', '點開看看目前誰已經到了'),
    NOTIFICATION_EVENT_TYPE.ALERT_TRIGGERED => ('你設定的提醒出現了！', '${s('campus')} 現在有人在找人一起，趕快去看看'),
  };
}

class _NotificationTile extends ConsumerWidget {
  const _NotificationTile({required this.notification});

  final generated.Notification notification;

  void _open(BuildContext context, WidgetRef ref) {
    final client = ref.read(supabaseClientProvider);
    if (notification.readAt == null) {
      // 安靜失敗即可——沒標成已讀頂多下次還看得到未讀角標，不影響導覽本身。
      markNotificationRead(client, notification.id).catchError((_) {});
    }
    final activityId = notification.payload['activity_id']?.toString();
    if (activityId != null && activityId.isNotEmpty) {
      context.push('/activity/$activityId');
      return;
    }
    if (notification.eventType == NOTIFICATION_EVENT_TYPE.ALERT_TRIGGERED) {
      // 沒有 activity_id/request_id 可導：這則通知本來就不指向任何一筆特定
      // 記錄（get_campus_pulse/ALERT_TRIGGERED 刻意只給聚合資訊，見
      // 20260801130200_alert_subscription_trigger.sql 的頭註解），導去首頁
      // 讓使用者自己發起新的 Request。
      context.go('/match');
      return;
    }
    // request_id 類通知（DOWNGRADE_*/MATCH_NOT_FORMED）：等到使用者點開時，
    // 那筆 Request 常常已經轉成別的狀態或已被背景任務結算掉，導去單一
    // waiting-room 反而可能撲空——一律導去「我的活動」清單，由清單自己依
    // 目前真實狀態呈現對的卡片。
    context.go('/my-activities');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (title, body) = _copyFor(notification);
    final unread = notification.readAt == null;
    final scheme = Theme.of(context).colorScheme;

    return AppCard(
      onTap: () => _open(context, ref),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: unread ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
