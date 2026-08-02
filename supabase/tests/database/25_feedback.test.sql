-- =============================================================================
-- pgTAP Test — 意見回饋 (submit_feedback) — v1.25
--
-- 涵蓋：
-- 1. 成功送出（不帶 activity_id）
-- 2. 成功送出（帶 activity_id，客服排查用的關聯資訊）
-- 3. 空白訊息應被 MESSAGE_REQUIRED (INVALID_INPUT) 擋下
-- 4. 超過 2000 字應被 MESSAGE_TOO_LONG (INVALID_INPUT) 擋下
-- 5. RLS：送出者自己看得到，別人查不到
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(10);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  author_id    uuid,
  other_id     uuid,
  deleted_id   uuid,
  activity_id  uuid
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_act_type_id  uuid;
  v_author_id    uuid := gen_random_uuid();
  v_other_id     uuid := gen_random_uuid();
  v_deleted_id   uuid := gen_random_uuid();
  v_activity_id  uuid;
  v_now          timestamptz := now();
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into auth.users (id, email) values
    (v_author_id, 'fb_author@nycu.edu.tw'),
    (v_other_id, 'fb_other@nycu.edu.tw'),
    (v_deleted_id, 'fb_deleted@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_author_id, 'fb_author@nycu.edu.tw', 'NYCU', 'FB Author', 'https://avatar.fbauthor', 'UNDERGRAD', 'fb_author_ig'),
    (v_other_id, 'fb_other@nycu.edu.tw', 'NYCU', 'FB Other', 'https://avatar.fbother', 'UNDERGRAD', 'fb_other_ig'),
    (v_deleted_id, 'fb_deleted@nycu.edu.tw', 'NYCU', 'FB Deleted', 'https://avatar.fbdeleted', 'UNDERGRAD', 'fb_deleted_ig');

  update app_user
     set email = 'deleted+' || v_deleted_id::text, deleted_at = now()
   where id = v_deleted_id;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status, contact_visible_until)
  values (v_act_type_id, 'NYCU', 'FB區', v_now, v_now + interval '90 minutes', 'ONGOING', v_now + interval '24 hours')
  returning id into v_activity_id;

  update fixtures set author_id = v_author_id, other_id = v_other_id, deleted_id = v_deleted_id, activity_id = v_activity_id;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select author_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 成功送出（不帶 activity_id）
-- -----------------------------------------------------------------------------

select lives_ok(
  $sql$select submit_feedback('這個 App 很好用，但地點選單有點卡')$sql$,
  '送出意見回饋應成功'
);

select is(
  (select count(*)::int from feedback
    where user_id = (select author_id from fixtures)
      and message = '這個 App 很好用，但地點選單有點卡'
      and activity_id is null),
  1,
  '回饋記錄應正確寫入，activity_id 未提供時應為 null'
);

-- -----------------------------------------------------------------------------
-- 2. 成功送出（帶 activity_id）
-- -----------------------------------------------------------------------------

select lives_ok(
  format($sql$select submit_feedback('這場活動的集合點資訊很清楚', %L, '1.0.0+1', 'ios')$sql$,
    (select activity_id from fixtures)),
  '送出帶 activity_id 的意見回饋應成功'
);

select is(
  (select app_version from feedback
    where user_id = (select author_id from fixtures)
      and activity_id = (select activity_id from fixtures)),
  '1.0.0+1',
  'app_version 應正確寫入'
);

select is(
  (select device_info from feedback
    where user_id = (select author_id from fixtures)
      and activity_id = (select activity_id from fixtures)),
  'ios',
  'device_info 應正確寫入'
);

-- -----------------------------------------------------------------------------
-- 3. 空白訊息應被擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select submit_feedback('   ')$sql$,
  'INVALID_INPUT',
  '空白訊息應被 MESSAGE_REQUIRED (INVALID_INPUT) 擋下'
);

-- -----------------------------------------------------------------------------
-- 4. 超過 2000 字應被擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select submit_feedback(%L)$sql$, repeat('字', 2001)),
  'INVALID_INPUT',
  '超過 2000 字應被 MESSAGE_TOO_LONG (INVALID_INPUT) 擋下'
);

-- -----------------------------------------------------------------------------
-- 4.1 已刪除帳號呼叫 submit_feedback 應被 ACCOUNT_DELETED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select deleted_id::text from fixtures), true);
end $$;

select throws_ok(
  $sql$select submit_feedback('已刪除帳號的回饋')$sql$,
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫 submit_feedback 應被 ACCOUNT_DELETED 擋下'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select author_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 5. RLS：送出者自己看得到，別人查不到
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select author_id::text from fixtures), true);
end $$;

select ok(
  exists (select 1 from feedback where user_id = (select author_id from fixtures)),
  '送出者自己看得到送出的回饋記錄'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select other_id::text from fixtures), true);
end $$;

select ok(
  not exists (select 1 from feedback where user_id = (select author_id from fixtures)),
  '別人查不到我送出的回饋記錄'
);

reset role;

select * from finish();

rollback;
