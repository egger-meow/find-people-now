-- =============================================================================
-- Realtime — 活動詳情頁訂閱失敗 (RealtimeSubscribeException / channelError)
-- =============================================================================
-- 反饋：activity_detail_screen 的 activityStreamProvider 訂閱 `activity`
-- 表（schema=public, filter=id=eq.<activity_id>）丟 channelError，「Unable to
-- subscribe to changes with given parameters」。
--
-- 診斷（跟 20260724124800_realtime_match_request.sql、
-- 20260730090000_realtime_notification.sql 是同一個根因、同一類 GAP）：
--   1. Realtime 本身有沒有開？有——這個專案的 realtime 服務本來就在跑，
--      match_request/request_member/notification 三張表都已經訂閱成功。
--   2. `activity` 有沒有在 supabase_realtime publication 裡？沒有——全 repo
--      搜尋 `alter publication supabase_realtime add table` 只出現在
--      20260724124800/20260730090000 兩支 migration，從未提過 `activity`。
--      postgres_changes 訂閱一張沒被加進 publication 的表，Realtime 伺服器就是
--      回這個 channelError，不是 filter 語法或 SDK 版本問題。
--   3. filter 語法（`id=eq.<uuid>`）本身沒問題，`supabase_flutter` 的
--      `.stream(primaryKey:...).eq(...)` 產生的就是這個格式，跟已經能正常訂閱
--      的 match_request/notification 用的是同一套 client 版本、同一種寫法。
--   4. RLS 擋住複寫？`activity` 早就有 `my_activities_select` SELECT policy
--      （20260724120000_init.sql），不是遺漏；RLS 會限制訂閱者看得到哪些列的
--      變化，但不會讓「表沒加進 publication」這件事變成看起來像 RLS 問題。
--   5. postgres_changes vs broadcast：程式碼用的是
--      `client.from('activity').stream(...)`，這是 supabase_flutter 對
--      postgres_changes 的封裝，選型本身沒有錯，跟其餘畫面（等待室、通知頁）
--      用的是同一套 API。
--   6. 是不是最近的 migration 造成的？不是新增的回歸，是從
--      20260724120000_init.sql 建表以來就從未補過這一步，只是這幾輪才依序
--      把 UI 實際接上 Realtime，一路暴露出同一個系統性缺口。
--
-- 順便一併補上同一份 `activity_detail_providers.dart` 裡另外三個一樣在用
-- `.stream()`、但同樣從未進 publication 的表（地點提案/投票/集合地點更新，
-- 一起在「地點」分頁籤即時運作，不能只修 activity 本身而漏了它們），以及
-- `downgrade_providers.dart` 用 `.stream()` 訂閱的 `downgrade_request`
-- （§6.2 人數調整同意流程，同一個系統性缺口，這裡一併補齊，不留下一個
-- 同類 bug 等下一輪才被回報）。
--
-- RLS 全部走既有 SELECT policy，不需要額外開權限。
-- =============================================================================

alter publication supabase_realtime add table activity;
alter publication supabase_realtime add table activity_location_option;
alter publication supabase_realtime add table activity_location_vote;
alter publication supabase_realtime add table activity_meeting_point_update;
alter publication supabase_realtime add table downgrade_request;
