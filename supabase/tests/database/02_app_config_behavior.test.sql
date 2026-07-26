-- =============================================================================
-- pgTAP Test — app_config 真的生效 (v1.8)
-- 目的：不只测试「预设值行为正确」，而是把 app_config 的值改成跟 SPEC 预设
-- 不同的数字，再实际呼叫 RPC，断言其效果确实跟着新值走——如果 RPC 内部
-- 还残留任何写死的 interval，这份测试会失败，而不是巧合地跟预设值一样而通过。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，對 app_config 的改動測試結束後自動還原。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

-- -----------------------------------------------------------------------------
-- 0. 把 app_config 改成跟 SPEC 預設值不同的數字，
--    確保後面的斷言不會因為「剛好跟舊寫死值一樣」而巧合通過
-- -----------------------------------------------------------------------------

do $$ begin
  update app_config set value = '1 minute', updated_at = now() where key = 'cooldown_minutes';
  update app_config set value = '2 minutes', updated_at = now() where key = 'confirm_window_minutes';
end $$;

select is(
  fn_get_config_interval('cooldown_minutes'),
  '1 minute'::interval,
  'fn_get_config_interval 應讀回剛更新的 cooldown_minutes 新值 (1 分鐘)'
);

select is(
  fn_get_config_interval('confirm_window_minutes'),
  '2 minutes'::interval,
  'fn_get_config_interval 應讀回剛更新的 confirm_window_minutes 新值 (2 分鐘，非舊寫死的 10 分鐘)'
);

-- -----------------------------------------------------------------------------
-- 1. Setup：兩個各 1 人的 Request，讓 commit_match 走 <=2 人的 pending_confirmation 分支
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_a_id uuid,
  user_b_id uuid,
  act_type_id uuid,
  campus text,
  req_a_id uuid,
  req_b_id uuid,
  pc_id uuid,
  activity_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_user_a_id   uuid := gen_random_uuid();
  v_user_b_id   uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_req_a       match_request;
  v_req_b       match_request;
begin
  insert into auth.users (id, email) values
    (v_user_a_id, 'cfg_a@nycu.edu.tw'),
    (v_user_b_id, 'cfg_b@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig, contact_line) values
    (v_user_a_id, 'cfg_a@nycu.edu.tw', 'NYCU', 'Cfg A', 'https://avatar.cfg_a', 'MASTER', 'cfg_a_ig', 'cfg_a_line'),
    (v_user_b_id, 'cfg_b@nycu.edu.tw', 'NYCU', 'Cfg B', 'https://avatar.cfg_b', 'MASTER', 'cfg_b_ig', 'cfg_b_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  -- v1.11：location 新增 campus，match_request/activity 存 (school, campus) 而非 campus_location_id
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '浩然圖書館前廣場', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_a_id, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 2, 'REQUESTING'
  ) returning * into v_req_a;
  insert into request_member (request_id, user_id, role, status)
  values (v_req_a.id, v_user_a_id, 'OWNER', 'JOINED');

  insert into match_request (
    owner_id, activity_type_id, school, campus,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_b_id, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 2, 'REQUESTING'
  ) returning * into v_req_b;
  insert into request_member (request_id, user_id, role, status)
  values (v_req_b.id, v_user_b_id, 'OWNER', 'JOINED');

  update fixtures set
    user_a_id = v_user_a_id, user_b_id = v_user_b_id,
    act_type_id = v_act_type_id, campus = v_campus,
    req_a_id = v_req_a.id, req_b_id = v_req_b.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 2. commit_match：2 人應進入 pending_confirmation 分支 (回傳 null，不建立 Activity)，
--    且 confirm_window_expire_at 應以新的 2 分鐘為準，而非舊寫死的 10 分鐘
-- -----------------------------------------------------------------------------

select is(
  (select commit_match((select req_a_id from fixtures), (select req_b_id from fixtures))),
  null,
  '總撮合人數 = 2（<=2）應進入 pending_confirmation 分支，commit_match 回傳 null、不建立 Activity'
);

do $$ begin
  update fixtures set pc_id = (
    select id from pending_confirmation
     where request_a_id = (select req_a_id from fixtures)
       and request_b_id = (select req_b_id from fixtures)
     order by created_at desc limit 1
  );
end $$;

select ok(
  abs(extract(epoch from (
    (select confirm_window_expire_at from pending_confirmation where id = (select pc_id from fixtures))
    - now()
  )) - 120) < 30,
  'confirm_window_expire_at 應約為 now() + 2 分鐘（app_config 新值），而非舊寫死的 10 分鐘'
);

-- -----------------------------------------------------------------------------
-- 3. respond_pending_confirmation(confirm=false)：冷卻時間應以新的 1 分鐘為準，
--    而非舊寫死的 30 分鐘
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_a_id::text from fixtures), true);
  perform respond_pending_confirmation((select pc_id from fixtures), false);
end $$;

select ok(
  abs(extract(epoch from (
    (select next_request_allowed_at from app_user where id = (select user_a_id from fixtures))
    - now()
  )) - 60) < 30,
  'DECLINED 後 next_request_allowed_at 應約為 now() + 1 分鐘（app_config 新值），而非舊寫死的 30 分鐘'
);

-- -----------------------------------------------------------------------------
-- 4. cancel_activity_participation：LATE_CANCEL 是 cooldown_minutes 的第二個呼叫點
--    (rpc_activity_and_contacts.sql)，跟第 3 節的 DECLINED 分支各自獨立寫死過
--    interval，任一處漏改都要能被抓到。用 user_b（未被前面步驟動過）確保乾淨。
-- -----------------------------------------------------------------------------

do $activity_setup$
declare
  v_activity activity;
begin
  insert into activity (
    activity_type_id, school, campus, start_time, estimated_end_time, status
  ) values (
    (select act_type_id from fixtures), 'NYCU', (select campus from fixtures),
    now() - interval '10 minutes', now() + interval '50 minutes', 'MATCHED'
  ) returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity.id, (select user_b_id from fixtures), (select req_b_id from fixtures), 'JOINED');

  update fixtures set activity_id = v_activity.id;
end;
$activity_setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_b_id::text from fixtures), true);
end $$;

select is(
  (select (cancel_activity_participation((select activity_id from fixtures)))->>'event_type'),
  'LATE_CANCEL',
  'start_time 已過，取消應判定為 LATE_CANCEL（觸發 cooldown）而非 EARLY_CANCEL'
);

select ok(
  abs(extract(epoch from (
    (select next_request_allowed_at from app_user where id = (select user_b_id from fixtures))
    - now()
  )) - 60) < 30,
  'LATE_CANCEL 後 next_request_allowed_at 應約為 now() + 1 分鐘（app_config 新值），而非舊寫死的 30 分鐘'
);

select * from finish();

rollback;
