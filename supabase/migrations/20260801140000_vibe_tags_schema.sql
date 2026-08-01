-- =============================================================================
-- Vibe Tags — schema (v1.28)
--
-- 跟 meeting_hint 同一種形狀（個人化、覆寫不留歷史、不觸發通知），刻意不
-- 是新表：每人在每個 activity 只有一組當下的 tags，沒有「歷史」需求。
--
-- 刻意設計成**配對成立後才填**（`activity_member` 而非 `request_member`）：
-- 使用者要求「不要當成配對篩選條件」，把欄位掛在配對前的 match_request/
-- request_member 只會誘使未來的自己「順手」拿來當篩選欄位；掛在配對後的
-- activity_member 讓這件事在結構上就不可能發生——matching engine 完全不
-- 碰這張表的這個欄位。也因此不需要碰 matching engine／
-- respond_pending_confirmation 任何一段既有邏輯，變更面完全侷限在
-- update_vibe_tags 這一支新 RPC。
--
-- 標籤清單本身刻意不做成後端表（不像 activity_type 有審核流程）：純展示、
-- 不影響配對邏輯，跟 department_options.dart 的既有取捨同一個精神——寫死在
-- app 端（依活動類型關鍵字比對，見 create_request_screen.dart 的
-- `_activityTypeIcon` 先例），標籤清單走鐘，使用者仍能透過這裡的自由文字
-- 欄位表達，不因為前端清單沒更新就卡住。
-- =============================================================================

-- 只在 DB 層加陣列長度上限（純量函式，CHECK 語意單純安全）。單一標籤字數
--上限（≤20 字）刻意只在 update_vibe_tags RPC 層擋，不比照 meeting_hint 那樣
-- 做成 DB 層 CHECK 雙重防線——array 逐筆長度檢查需要在 CHECK 內對欄位值跑
-- unnest()，這類「陣列元素逐一驗證」的 CHECK 寫法在 Postgres 裡地雷較多
-- （值得日後有把握測試過再補），這裡先用單層 RPC 驗證，不引入沒有本地
-- Supabase 環境驗證過的 DB constraint。
alter table activity_member add column vibe_tags text[];

alter table activity_member add constraint activity_member_vibe_tags_count_check
  check (vibe_tags is null or array_length(vibe_tags, 1) <= 3);
