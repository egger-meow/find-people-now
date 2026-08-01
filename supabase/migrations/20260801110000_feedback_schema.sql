-- =============================================================================
-- Feedback — schema (v1.25)
--
-- 跟 `report`（11.4/11.5）同一種形狀：使用者送出的一次性紀錄，本人可回讀
-- 自己送出的，其餘人（含被提及的活動其他成員）看不到。差別是 feedback 沒有
-- 「審核狀態」欄位——report 走人工審核流程（pending_review），feedback 純粹
-- 是「送給我看」的訊息，不需要狀態機。
--
-- 刻意不做成 `report.category` 那種枚舉分類：意見回饋的形狀比檢舉開放得多
-- （bug、建議、稱讚都可能），加分類枚舉只會逼使用者硬塞進不合適的選項，
-- 自由文字 + 可選的關聯活動就足夠支撐第一輪。
-- =============================================================================

create table feedback (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references app_user (id),
  message      text not null check (char_length(message) between 1 and 2000),
  activity_id  uuid references activity (id),
  app_version  text,
  device_info  text,
  created_at   timestamptz not null default now()
);

create index idx_feedback_user on feedback (user_id, created_at desc);

alter table feedback enable row level security;

create policy own_feedback_insert on feedback
  for insert with check (user_id = auth.uid());

create policy own_feedback_select on feedback
  for select using (user_id = auth.uid());

-- 只給 select——寫入一律走 submit_feedback()（SECURITY DEFINER），比照
-- CLAUDE.md 的既有硬性規則（所有狀態轉移只能走 RPC，不開放 client 直寫）。
grant select on feedback to authenticated;
