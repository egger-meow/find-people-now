-- =============================================================================
-- Alert Subscription — schema (v1.27)
--
-- 「羽球在光復校區 3 小時內出現就通知我」——訂閱 (activity_type, school,
-- campus) 這個組合，`expires_at` 就是使用者願意等待的那段時間，不是被訂閱
-- 對象（某個活動）的屬性。跟 `app_user.next_request_allowed_at`／
-- `suspended_until` 同一種「軟性到期」設計：不開背景任務清除，觸發時機用
-- `expires_at > now()` 篩選即可，過期的列就靜靜留著（同既有慣例，見
-- SPEC v1.27 變更紀錄）。
--
-- 一人最多同時 5 筆有效訂閱（RPC 層擋，見 alert_subscription_rpc.sql）：
-- 純粹防呆／防洗版，不是資安邊界。
-- =============================================================================

create table activity_alert_subscription (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references app_user (id),
  activity_type_id  uuid not null references activity_type (id),
  school            school not null,
  campus            text not null,
  expires_at        timestamptz not null,
  created_at        timestamptz not null default now()
);

-- submit_request 的觸發查詢路徑：依 (activity_type_id, school, campus)
-- 找出仍有效（expires_at > now()）的訂閱。
create index idx_activity_alert_subscription_match
  on activity_alert_subscription (activity_type_id, school, campus, expires_at);

create index idx_activity_alert_subscription_user
  on activity_alert_subscription (user_id, expires_at);

alter table activity_alert_subscription enable row level security;

create policy own_activity_alert_subscription_select on activity_alert_subscription
  for select using (user_id = auth.uid());

-- 寫入一律走 RPC（subscribe_activity_alert/unsubscribe_activity_alert），
-- 比照 user_block／CLAUDE.md 的既有硬性規則，不開放 client 直寫。
grant select on activity_alert_subscription to authenticated;

alter type notification_event_type add value if not exists 'ALERT_TRIGGERED';
