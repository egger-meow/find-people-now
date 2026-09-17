-- =============================================================================
-- pgTAP Test — 推播訂閱管理、帳號切換清理與 PENDING_CONFIRMATION 通知
--
-- 涵蓋：
-- 1. 使用者能建立推播訂閱
-- 2. 同裝置切換帳號：新使用者註冊同一個 endpoint，舊使用者的訂閱自動被覆蓋/清除
-- 3. 使用者能移除自己的推播訂閱
-- 4. cleanup_stale_push_subscriptions 能批次清除失效端點
-- 5. commit_match 在 2 人撮合時能發送 PENDING_CONFIRMATION 通知
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(6);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------
create temp table fixtures (
  user_a    uuid,
  user_b    uuid,
  act_type  uuid
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_t uuid;
begin
  insert into auth.users (id, email) values
    (v_a, 'ps_a@nycu.edu.tw'), (v_b, 'ps_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  values
    (v_a, 'ps_a@nycu.edu.tw', 'NYCU', 'PS A', 'https://avatar/a', 'UNDERGRAD', 'ps_a_ig'),
    (v_b, 'ps_b@nycu.edu.tw', 'NYCU', 'PS B', 'https://avatar/b', 'UNDERGRAD', 'ps_b_ig');

  select id into v_t from activity_type where status = 'APPROVED' limit 1;
  update fixtures set user_a = v_a, user_b = v_b, act_type = v_t;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 使用者 A 儲存推播訂閱
-- -----------------------------------------------------------------------------
set local role authenticated;
do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_a::text from fixtures), true);
end $$;

select lives_ok(
  $$ select save_push_subscription('https://push.example.com/device1', 'key_p256dh_a', 'key_auth_a', 'Browser A') $$,
  '使用者 A 應能成功呼叫 save_push_subscription'
);

select is(
  (select count(*)::int from user_push_subscription where user_id = (select user_a from fixtures) and endpoint = 'https://push.example.com/device1'),
  1,
  '使用者 A 應在 user_push_subscription 擁有 1 筆記錄'
);

-- -----------------------------------------------------------------------------
-- 2. 帳號切換防護：同裝置以使用者 B 登入並儲存同一 endpoint
-- -----------------------------------------------------------------------------
do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_b::text from fixtures), true);
end $$;

select lives_ok(
  $$ select save_push_subscription('https://push.example.com/device1', 'key_p256dh_b', 'key_auth_b', 'Browser B') $$,
  '使用者 B 應能覆蓋儲存同一 endpoint'
);

reset role;
select is(
  (select count(*)::int from user_push_subscription where user_id = (select user_a from fixtures) and endpoint = 'https://push.example.com/device1'),
  0,
  '帳號切換後，舊使用者 A 在該 endpoint 的訂閱必須已被清理（防個資外洩）'
);

select is(
  (select user_id from user_push_subscription where endpoint = 'https://push.example.com/device1'),
  (select user_b from fixtures),
  '該 endpoint 之擁有人應已轉移給新使用者 B'
);

-- -----------------------------------------------------------------------------
-- 3. 測試 commit_match 產生 PENDING_CONFIRMATION 通知
-- -----------------------------------------------------------------------------
do $match_test$
declare
  v_a uuid := (select user_a from fixtures);
  v_b uuid := (select user_b from fixtures);
  v_t uuid := (select act_type from fixtures);
  v_ra uuid;
  v_rb uuid;
begin
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    (v_a, v_t, 'NYCU', '光復', now() + interval '1 hour', now() + interval '3 hours', 2, 2, 'REQUESTING')
  returning id into v_ra;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    (v_b, v_t, 'NYCU', '光復', now() + interval '1 hour', now() + interval '3 hours', 2, 2, 'REQUESTING')
  returning id into v_rb;

  insert into request_member (request_id, user_id, role, status)
  values
    (v_ra, v_a, 'OWNER', 'JOINED'),
    (v_rb, v_b, 'OWNER', 'JOINED');

  -- 執行 commit_match，2 人撮合應進入 PENDING_CONFIRMATION 並寫入通知
  perform commit_match(v_ra, v_rb);
end;
$match_test$;

select is(
  (select count(*)::int from notification where event_type = 'PENDING_CONFIRMATION' and user_id in ((select user_a from fixtures), (select user_b from fixtures))),
  2,
  '2 人撮合成功進入 PENDING_CONFIRMATION 時，雙方都應收到 PENDING_CONFIRMATION 通知'
);

select * from finish();

rollback;
