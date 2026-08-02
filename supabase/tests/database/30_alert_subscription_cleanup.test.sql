-- =============================================================================
-- pgTAP Test — fn_cleanup_alert_subscriptions (v1.27.1)
-- 涵蓋：已過期的訂閱被清掉、未過期的不受影響、回傳值是實際清掉的列數
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(3);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_id       uuid,
  basketball_id uuid,
  campus        text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_user       uuid := gen_random_uuid();
  v_basketball uuid;
  v_campus     text := 'ASC測試區';
begin
  select id into v_basketball from activity_type where name = '籃球' limit 1;

  insert into auth.users (id, email) values (v_user, 'asc_user@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_user, 'asc_user@nycu.edu.tw', 'NYCU', 'ASC User', 'https://avatar.ascuser', 'UNDERGRAD', 'asc_user_ig');

  -- 2 筆已過期，1 筆未過期
  insert into activity_alert_subscription (user_id, activity_type_id, school, campus, expires_at) values
    (v_user, v_basketball, 'NYCU', v_campus, now() - interval '1 minute'),
    (v_user, v_basketball, 'NYCU', v_campus || '2', now() - interval '1 hour'),
    (v_user, v_basketball, 'NYCU', v_campus || '3', now() + interval '1 hour');

  update fixtures set user_id = v_user, basketball_id = v_basketball, campus = v_campus;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. fn_cleanup_alert_subscriptions 回傳實際清掉的列數（2）
-- -----------------------------------------------------------------------------

select is(
  (select fn_cleanup_alert_subscriptions()),
  2,
  'fn_cleanup_alert_subscriptions 應回傳實際清掉的過期列數'
);

-- -----------------------------------------------------------------------------
-- 2. 已過期的訂閱應被清掉
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from activity_alert_subscription
    where user_id = (select user_id from fixtures) and expires_at <= now()),
  0,
  '已過期的訂閱應被清乾淨'
);

-- -----------------------------------------------------------------------------
-- 3. 未過期的訂閱不受影響
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from activity_alert_subscription
    where user_id = (select user_id from fixtures) and expires_at > now()),
  1,
  '未過期的訂閱不應被清掉'
);

select * from finish();

rollback;
