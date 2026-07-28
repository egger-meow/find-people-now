-- =============================================================================
-- 檢舉機制 — RPC（v1.18）
-- 派生自 docs/API.md（submit_report，本輪新增）
-- =============================================================================

create or replace function submit_report(
  p_category              report_category,
  p_reported_user_id      uuid default null,
  p_reported_activity_id  uuid default null,
  p_detail                text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if p_reported_user_id is null and p_reported_activity_id is null then
    raise exception using message = 'INVALID_INPUT', detail = 'REPORT_TARGET_REQUIRED';
  end if;

  insert into report (reporter_id, reported_user_id, reported_activity_id, category, detail)
  values (v_user_id, p_reported_user_id, p_reported_activity_id, p_category, p_detail);
end;
$$;
