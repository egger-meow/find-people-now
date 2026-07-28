-- =============================================================================
-- pgTAP Test — 檢舉機制 (submit_report) — v1.18
--
-- 涵蓋：
-- 1. 檢舉使用者成功寫入（status 預設 PENDING）
-- 2. 檢舉活動成功寫入
-- 3. 兩個 target 皆為 null 應被 REPORT_TARGET_REQUIRED 擋下
-- 4. RLS：檢舉發起人自己看得到，別人查不到
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  reporter_id  uuid,
  reported_id  uuid,
  other_id     uuid,
  activity_id  uuid
);
insert into fixtures default values;

-- 測試 4 之後會 `set local role authenticated` 來實測 RLS，該角色也要能讀
-- 這張 temp fixtures 表才能取得 reporter_id
grant select on fixtures to authenticated;

do $setup$
declare
  v_act_type_id  uuid;
  v_reporter_id  uuid := gen_random_uuid();
  v_reported_id  uuid := gen_random_uuid();
  v_other_id     uuid := gen_random_uuid();
  v_activity_id  uuid;
  v_now          timestamptz := now();
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into auth.users (id, email) values
    (v_reporter_id, 'rp_reporter@nycu.edu.tw'),
    (v_reported_id, 'rp_reported@nycu.edu.tw'),
    (v_other_id, 'rp_other@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_reporter_id, 'rp_reporter@nycu.edu.tw', 'NYCU', 'RP Reporter', 'https://avatar.rpreporter', 'UNDERGRAD', 'rp_reporter_ig'),
    (v_reported_id, 'rp_reported@nycu.edu.tw', 'NYCU', 'RP Reported', 'https://avatar.rpreported', 'UNDERGRAD', 'rp_reported_ig'),
    (v_other_id, 'rp_other@nycu.edu.tw', 'NYCU', 'RP Other', 'https://avatar.rpother', 'UNDERGRAD', 'rp_other_ig');

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', 'RP區', v_now, v_now + interval '90 minutes', 'ONGOING', v_now + interval '24 hours')
  returning id into v_activity_id;

  update fixtures set
    reporter_id = v_reporter_id, reported_id = v_reported_id, other_id = v_other_id, activity_id = v_activity_id;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select reporter_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 檢舉使用者成功寫入
-- -----------------------------------------------------------------------------

select lives_ok(
  $sql$select submit_report('HARASSMENT'::report_category, (select reported_id from fixtures), null, '對方持續騷擾')$sql$,
  '檢舉使用者應成功'
);

select is(
  (select count(*)::int from report
    where reporter_id = (select reporter_id from fixtures)
      and reported_user_id = (select reported_id from fixtures)
      and status = 'PENDING'),
  1,
  '檢舉使用者記錄應寫入，status 預設 PENDING'
);

-- -----------------------------------------------------------------------------
-- 2. 檢舉活動成功寫入
-- -----------------------------------------------------------------------------

select lives_ok(
  $sql$select submit_report('SPAM'::report_category, null, (select activity_id from fixtures))$sql$,
  '檢舉活動應成功'
);

select is(
  (select count(*)::int from report
    where reporter_id = (select reporter_id from fixtures)
      and reported_activity_id = (select activity_id from fixtures)),
  1,
  '檢舉活動記錄應寫入'
);

-- -----------------------------------------------------------------------------
-- 3. 兩個 target 皆為 null 應被擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select submit_report('OTHER'::report_category)$sql$,
  'INVALID_INPUT',
  '兩個檢舉對象皆缺應被 REPORT_TARGET_REQUIRED (INVALID_INPUT) 擋下'
);

-- -----------------------------------------------------------------------------
-- 4. RLS：檢舉發起人自己看得到，別人查不到
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select reporter_id::text from fixtures), true);
end $$;

select ok(
  exists (select 1 from report where reporter_id = (select reporter_id from fixtures)),
  '檢舉發起人自己看得到送出的檢舉記錄'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select other_id::text from fixtures), true);
end $$;

select ok(
  not exists (select 1 from report where reporter_id = (select reporter_id from fixtures)),
  '別人查不到我送出的檢舉記錄'
);

reset role;

select * from finish();

rollback;
