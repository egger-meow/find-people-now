-- =============================================================================
-- Alert Subscription 過期清理背景任務 + pg_cron 排程
--
-- 根因：20260801130000_alert_subscription_schema.sql 的檔頭註解明講「不開
-- 背景任務清除，過期的列就靜靜留著」，並類比 app_user.next_request_allowed_at／
-- suspended_until 的「軟性到期」設計。這個類比不成立：next_request_allowed_at
-- 是 app_user 上每人一欄、每次都被覆寫的值，列數固定不變；
-- activity_alert_subscription 是每呼叫一次 subscribe_activity_alert 就新增
--一列，過期後從不刪除，是會隨使用量無限累積的表，不是同一種「軟性到期」。
--
-- 沿用既有背景任務慣例（fn_expire_requests 等）：回傳實際清掉的列數，
-- 方便未來需要時觀察執行成效；跟其餘背景任務一樣掛進 pg_cron。
--
-- 頻率選 15 分鐘：這張表清理不清理不影響任何功能正確性（過期的訂閱本來就已經
-- 被 subscribe_activity_alert/submit_request 的 expires_at > now() 條件排除，
-- 純粹是資料庫容量問題），跟 fn_complete_activities()/
-- fn_remind_upcoming_activities() 同一組「誤差不影響體驗」頻率，起點錯開
-- 12 分鐘避免撞在同一刻。
-- =============================================================================

create or replace function fn_cleanup_alert_subscriptions()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  delete from activity_alert_subscription where expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

select cron.schedule('cleanup-alert-subscriptions', '12-59/15 * * * *', $$select fn_cleanup_alert_subscriptions();$$);
