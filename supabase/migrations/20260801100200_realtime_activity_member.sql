-- =============================================================================
-- Arrival Check（「我到了」）— Realtime (v1.22)
--
-- activity_member 先前刻意不進 supabase_realtime publication（成員名單走
-- FutureProvider + 下拉刷新，見 app/lib/activities/activity_detail_providers.dart
-- 的既有註解：「不像地點投票有即時得票數的明確需求」）。抵達狀態明確需要
-- 即時性（本 App 目前所有其他即時場景都已加進這個 publication，見
-- 20260724124800/20260730090000/20260730093000 三個先例），所以這裡補上。
-- =============================================================================

alter publication supabase_realtime add table activity_member;
