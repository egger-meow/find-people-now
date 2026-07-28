-- =============================================================================
-- 檢舉機制 — schema（v1.18）
-- 派生自使用者需求：檢舉使用者或活動，審核走 Supabase Studio 人工查詢
-- status='PENDING'，不新建 admin API/介面。
-- =============================================================================

create type report_category as enum ('SPAM', 'HARASSMENT', 'OTHER');
create type report_status   as enum ('PENDING', 'REVIEWED');

create table report (
  id                    uuid primary key default gen_random_uuid(),
  reporter_id           uuid not null references app_user (id),
  reported_user_id      uuid references app_user (id),
  reported_activity_id  uuid references activity (id),
  category              report_category not null,
  detail                text,
  status                report_status not null default 'PENDING',
  created_at            timestamptz not null default now(),
  constraint report_has_target check (reported_user_id is not null or reported_activity_id is not null)
);

-- 使用者查自己送出的檢舉記錄用
create index idx_report_reporter on report (reporter_id);

-- admin 在 Supabase Studio 查 status='PENDING' 用
create index idx_report_status on report (status);

-- RLS：只有檢舉發起人自己看得到這筆記錄
alter table report enable row level security;

create policy own_reports_select on report
  for select using (reporter_id = auth.uid());

-- 清單查詢直接用 PostgREST（GET report?reporter_id=eq.<self>），不需額外 RPC；
-- 寫入一律走 submit_report（SECURITY DEFINER RPC），故不 grant insert；
-- 審核（status 更新）走 Supabase Studio 的 service_role 連線，不 grant update 給 authenticated。
grant select on report to authenticated;
