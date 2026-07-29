import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../generated/notification.dart' as generated;

/// UI_PLAN.md §5 通知——`notification` 已有 `grant select, update (read_at)
/// on notification to authenticated`（見
/// supabase/migrations/20260724125200_restrict_app_user_notification_column_grants.sql），
/// RLS 只放行 `user_id = auth.uid()`，不需要額外 RPC。用 Realtime `.stream()`
/// 而非手動刷新的 FutureProvider——跟等待室/地點投票同一個既有先例（見
/// lib/match/match_providers.dart 開頭註解），通知本來就該即時出現，不用等
/// 使用者自己下拉。
///
/// 別名匯入 `generated` 前綴：`Notification` 這個類名跟 Flutter 框架本身的
/// `widgets/notification.dart`（`NotificationListener` 的事件基底類別）撞名，
/// 直接 import 會遮蔽框架型別。
final notificationsStreamProvider = StreamProvider<List<generated.Notification>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const []);
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('notification')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) {
        final list = rows.map(generated.Notification.fromJson).toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list;
      });
});

/// 底部導覽「通知」tab 的未讀角標——衍生自上面同一條 stream，不另外查詢。
final unreadNotificationCountProvider = Provider<int>((ref) {
  final notifications = ref.watch(notificationsStreamProvider).value ?? const [];
  return notifications.where((n) => n.readAt == null).length;
});

/// 點擊通知時標記已讀——欄位授權只放行 `read_at`（同上的 column-grant 收斂），
/// 直接 PostgREST PATCH 即可，不需要 RPC。
Future<void> markNotificationRead(SupabaseClient client, String id) {
  return client.from('notification').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);
}
