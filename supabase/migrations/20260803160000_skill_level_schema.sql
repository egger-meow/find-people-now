-- =============================================================================
-- Skill Level（競技類型技能程度）—— schema (v1.34)
-- =============================================================================
-- activity_type.skill_level_enabled 沿用 group_size_step（20260724120050）建立的
-- 「per-type 設定欄位」模式：matching engine 與前端都讀這個欄位決定要不要啟用程度
-- 篩選，不寫死判斷邏輯（例如 if name = '籃球'）。這樣任何未來新增的競技類型
-- （含使用者提案審核通過的）都能由 admin 在審核當下直接打開這個 flag，不需要
-- 改任何 RPC 或前端程式碼——跟 group_size_step 一樣，都是在 Studio 手動設定，
-- 沒有專屬的 admin RPC。
--
-- match_request.skill_level 是 nullable：null = 不限（wildcard，可跟任何人配對，
-- 含其他 null 及任何指定等級）。4 個等級對應「新手/一般/進階/競技」。
create type skill_level as enum ('BEGINNER', 'CASUAL', 'ADVANCED', 'COMPETITIVE');

alter table activity_type
  add column skill_level_enabled boolean not null default false;

alter table match_request
  add column skill_level skill_level;

-- 官方既有類型：只有籃球/羽球開啟，其餘維持 false（預設值本來就是 false，
-- 這裡明確寫出來只是為了讓意圖在 migration 歷史上可查）。
update activity_type set skill_level_enabled = true where name in ('籃球', '羽球');
