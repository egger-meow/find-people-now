import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../generated/downgrade_request.dart';
import '../generated/supadart_header.dart' show DOWNGRADE_RESPONSE;

/// UI_PLAN.md §6.2 人數調整同意——`downgrade_request` 的 RLS
/// (`my_downgrades_select`) 已經限定「只有這筆的 `downgrade_consent` 裡有
/// 自己的成員才看得到」，所以這裡不需要額外加 `.eq('request_id', ...)`
/// 之類的過濾，直接篩 `status = 'PENDING'` 就是「輪到我表態的那些」。用
/// Realtime `.stream()`——跟本專案其餘「需要即時反應狀態變化」的畫面
/// （等待室、地點投票）同一個既有模式，Downgrade 彈窗本來就該主動跳出，
/// 不能等使用者自己發現。
final pendingDowngradesStreamProvider = StreamProvider<List<DowngradeRequest>>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client
      .from('downgrade_request')
      .stream(primaryKey: ['id'])
      .eq('status', 'PENDING')
      .map((rows) => rows.map(DowngradeRequest.fromJson).toList());
});

/// 我自己對某一筆 downgrade_request 的回應狀態——`downgrade_consent` 的 RLS
/// (`my_consents_select`) 只放行 `user_id = auth.uid()`，所以這支查詢天然
/// 只回傳「我自己那一列」，用來判斷彈窗要不要再跳出來（已經回應過的不用）。
final myDowngradeResponseProvider =
    FutureProvider.family<DOWNGRADE_RESPONSE?, String>((ref, downgradeRequestId) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final client = ref.watch(supabaseClientProvider);
  final row = await client
      .from('downgrade_consent')
      .select()
      .eq('downgrade_request_id', downgradeRequestId)
      .eq('user_id', userId)
      .maybeSingle();
  if (row == null) return null;
  return DOWNGRADE_RESPONSE.values.byName(row['response'] as String);
});
