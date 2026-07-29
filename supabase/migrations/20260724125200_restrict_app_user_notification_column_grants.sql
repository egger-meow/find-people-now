-- =============================================================================
-- 收斂 app_user / notification 的 column-level UPDATE 授權（安全性修補）
--
-- 根因：20260724120800_grants.sql 對這兩張表下的是
--   `grant select, update on app_user to authenticated;`
--   `grant select, update on notification to authenticated;`
-- 沒有 column list，等於 authenticated 對「整列」都有 UPDATE 權限，只被
-- RLS 的 `using (id = auth.uid())` / `using (user_id = auth.uid())` 擋
-- 「哪一列」，完全沒擋「哪一欄」。
--
-- 這個決定是 20260724124600_onboarding_seen_at.sql 刻意選的：為了讓前端能
-- 直接 PATCH app_user.onboarding_seen_at（不開新 RPC），複用了既有的
-- 全欄位 grant + own_profile_update policy。副作用是同一個 grant 也放行了
-- app_user.suspended_until——也就是任何被停權中的使用者，可以自己對
-- `/rest/v1/app_user?id=eq.<self>` PATCH `{"suspended_until": null}`，
-- 完全繞過「連續 3 次 No-show 停權 7 天」的懲罰機制，不需要碰任何 RPC。
-- email / school / created_at 同樣暴露（school 有 CHECK 擋不一致，但
-- email 可被改成任意合法 .edu.tw 格式字串、created_at 可被改寫進而影響
-- 未來可能依註冊時間判斷資淺/資深的邏輯）。
--
-- 修法：收回整欄授權，改成只放行前端本來就該能直接改的欄位；
-- suspended_until / email / school / created_at / id 完全不給 authenticated
-- 寫入權限，只有 service_role（及未來需要時的 SECURITY DEFINER RPC）能動。
-- =============================================================================

revoke update on app_user from authenticated;
grant update (
  display_name,
  avatar_url,
  gender,
  bio,
  contact_ig,
  contact_line,
  contact_discord,
  onboarding_seen_at
) on app_user to authenticated;

-- notification 同理收斂：使用者只該能把自己的通知標記已讀，
-- event_type / payload 不該是前端可寫欄位（雖然只影響自己看到的內容，
-- 屬於低風險，但比照同一次修補一併收斂，避免留下同類型的口子）。
revoke update on notification from authenticated;
grant update (read_at) on notification to authenticated;
