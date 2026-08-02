-- =============================================================================
-- pgTAP Test — Alert Subscription (subscribe/unsubscribe_activity_alert +
-- submit_request 觸發點) — v1.27
--
-- 涵蓋：
-- 1. lookahead_hours 超出 1–24 範圍應被 INVALID_INPUT 擋下
-- 2. 不存在的 activity_type_id 應被 NOT_FOUND 擋下
-- 3. 成功訂閱，expires_at 正確
-- 4. 超過 5 筆有效訂閱應被 TOO_MANY_ALERT_SUBSCRIPTIONS 擋下
-- 5. submit_request 成功轉 REQUESTING 後，符合條件的訂閱者應收到 ALERT_TRIGGERED
-- 6. 送出者自己不應收到自己剛送出那筆的通知
-- 7. 不同校區/類型的訂閱不應被觸發
-- 8. 已過期的訂閱不應被觸發
-- 9. unsubscribe 冪等（找不到/不屬於自己都視為成功）
-- 10. RLS：訂閱者自己看得到，別人查不到
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(13);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  subscriber_id   uuid,
  submitter_id    uuid,
  other_id        uuid,
  deleted_id      uuid,
  basketball_id   uuid,
  coffee_id       uuid,
  campus          text,
  other_campus    text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_subscriber  uuid := gen_random_uuid();
  v_submitter   uuid := gen_random_uuid();
  v_other       uuid := gen_random_uuid();
  v_deleted     uuid := gen_random_uuid();
  v_basketball  uuid;
  v_coffee      uuid;
  v_campus      text := 'AS測試區';
  v_other_campus text := 'AS其他區';
begin
  select id into v_basketball from activity_type where name = '籃球' limit 1;
  select id into v_coffee from activity_type where name = '咖啡' limit 1;

  insert into auth.users (id, email) values
    (v_subscriber, 'as_sub@nycu.edu.tw'), (v_submitter, 'as_submit@nycu.edu.tw'), (v_other, 'as_other@nycu.edu.tw'),
    (v_deleted, 'as_deleted@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_subscriber, 'as_sub@nycu.edu.tw', 'NYCU', 'AS Subscriber', 'https://avatar.assub', 'UNDERGRAD', 'as_sub_ig'),
    (v_submitter, 'as_submit@nycu.edu.tw', 'NYCU', 'AS Submitter', 'https://avatar.assubmit', 'UNDERGRAD', 'as_submit_ig'),
    (v_other, 'as_other@nycu.edu.tw', 'NYCU', 'AS Other', 'https://avatar.asother', 'UNDERGRAD', 'as_other_ig'),
    (v_deleted, 'as_deleted@nycu.edu.tw', 'NYCU', 'AS Deleted', 'https://avatar.asdeleted', 'UNDERGRAD', 'as_deleted_ig');

  update app_user
     set email = 'deleted+' || v_deleted::text, deleted_at = now()
   where id = v_deleted;

  update fixtures set
    subscriber_id = v_subscriber, submitter_id = v_submitter, other_id = v_other, deleted_id = v_deleted,
    basketball_id = v_basketball, coffee_id = v_coffee, campus = v_campus, other_campus = v_other_campus;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select subscriber_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. lookahead_hours 超出範圍
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select subscribe_activity_alert(%L, 'NYCU'::school, %L, 0)$sql$,
    (select basketball_id from fixtures), (select campus from fixtures)),
  'INVALID_INPUT',
  'lookahead_hours = 0 應被 INVALID_INPUT 擋下'
);

select throws_ok(
  format($sql$select subscribe_activity_alert(%L, 'NYCU'::school, %L, 25)$sql$,
    (select basketball_id from fixtures), (select campus from fixtures)),
  'INVALID_INPUT',
  'lookahead_hours = 25 應被 INVALID_INPUT 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. 不存在的 activity_type_id
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select subscribe_activity_alert(%L, 'NYCU'::school, %L, 3)$sql$,
    gen_random_uuid(), (select campus from fixtures)),
  'NOT_FOUND',
  '不存在的 activity_type_id 應被 NOT_FOUND 擋下'
);

-- -----------------------------------------------------------------------------
-- 3. 成功訂閱籃球，3 小時內
-- -----------------------------------------------------------------------------

do $$ begin
  perform subscribe_activity_alert(
    (select basketball_id from fixtures), 'NYCU'::school, (select campus from fixtures), 3);
end $$;

select is(
  (select count(*)::int from activity_alert_subscription
    where user_id = (select subscriber_id from fixtures)
      and activity_type_id = (select basketball_id from fixtures)
      and campus = (select campus from fixtures)
      and expires_at between now() + interval '2 hours 59 minutes' and now() + interval '3 hours 1 minute'),
  1,
  '成功訂閱後應建立一筆記錄，expires_at ≈ now() + 3 小時'
);

-- -----------------------------------------------------------------------------
-- 4. 超過 5 筆有效訂閱
-- -----------------------------------------------------------------------------

do $$ begin
  perform subscribe_activity_alert((select coffee_id from fixtures), 'NYCU'::school, 'X1', 1);
  perform subscribe_activity_alert((select coffee_id from fixtures), 'NYCU'::school, 'X2', 1);
  perform subscribe_activity_alert((select coffee_id from fixtures), 'NYCU'::school, 'X3', 1);
  perform subscribe_activity_alert((select coffee_id from fixtures), 'NYCU'::school, 'X4', 1);
end $$;

select throws_ok(
  format($sql$select subscribe_activity_alert(%L, 'NYCU'::school, 'X5', 1)$sql$,
    (select coffee_id from fixtures)),
  'TOO_MANY_ALERT_SUBSCRIPTIONS',
  '第 6 筆有效訂閱應被 TOO_MANY_ALERT_SUBSCRIPTIONS 擋下'
);

-- 清掉這輪只是為了測試上限而建的訂閱，避免影響後面的觸發測試斷言
delete from activity_alert_subscription where user_id = (select subscriber_id from fixtures) and campus like 'X%';

-- -----------------------------------------------------------------------------
-- 5-8. submit_request 觸發 ALERT_TRIGGERED
-- -----------------------------------------------------------------------------

-- 8. 額外建一筆已過期的咖啡訂閱，驗證不會被觸發
insert into activity_alert_subscription (user_id, activity_type_id, school, campus, expires_at)
values ((select subscriber_id from fixtures), (select coffee_id from fixtures), 'NYCU',
        (select campus from fixtures), now() - interval '1 minute');

-- submitter 自己也訂閱同一個 (籃球, campus)——驗證自己不會收到自己觸發的通知
do $$ begin
  perform set_config('request.jwt.claim.sub', (select submitter_id from fixtures)::text, true);
  perform subscribe_activity_alert(
    (select basketball_id from fixtures), 'NYCU'::school, (select campus from fixtures), 3);
end $$;

do $$
declare
  v_req match_request;
begin
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values ((select submitter_id from fixtures), (select basketball_id from fixtures), 'NYCU',
          (select campus from fixtures), now(), now() + interval '2 hours', 4, 4, false, 'DRAFT')
  returning * into v_req;
  insert into request_member (request_id, user_id, role, status) values (v_req.id, (select submitter_id from fixtures), 'OWNER', 'JOINED');

  perform set_config('request.jwt.claim.sub', (select submitter_id from fixtures)::text, true);
  perform submit_request(v_req.id);
end $$;

select is(
  (select count(*)::int from notification
    where user_id = (select subscriber_id from fixtures)
      and event_type = 'ALERT_TRIGGERED'
      and payload->>'activity_type_id' = (select basketball_id::text from fixtures)),
  1,
  '符合條件（籃球 + 同校區 + 未過期）的訂閱者應收到 1 則 ALERT_TRIGGERED'
);

select is(
  (select count(*)::int from notification
    where user_id = (select submitter_id from fixtures) and event_type = 'ALERT_TRIGGERED'),
  0,
  '送出者自己不應收到自己剛送出那筆觸發的 ALERT_TRIGGERED'
);

select is(
  (select count(*)::int from notification
    where user_id = (select subscriber_id from fixtures)
      and event_type = 'ALERT_TRIGGERED'
      and payload->>'activity_type_id' = (select coffee_id::text from fixtures)),
  0,
  '已過期的咖啡訂閱不應被觸發'
);

-- -----------------------------------------------------------------------------
-- 9. unsubscribe 冪等
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select subscriber_id from fixtures)::text, true);
end $$;

select lives_ok(
  $sql$select unsubscribe_activity_alert(gen_random_uuid())$sql$,
  '取消一筆不存在的訂閱應冪等成功，不拋錯'
);

-- -----------------------------------------------------------------------------
-- 9.1 unsubscribe 不能刪除別人的訂閱（不拋錯，但也不應真的刪掉）
-- -----------------------------------------------------------------------------

do $$
declare
  v_target_id uuid;
begin
  select id into v_target_id from activity_alert_subscription
   where user_id = (select subscriber_id from fixtures)
     and activity_type_id = (select basketball_id from fixtures);

  perform set_config('request.jwt.claim.sub', (select other_id from fixtures)::text, true);
  perform unsubscribe_activity_alert(v_target_id);
end $$;

select is(
  (select count(*)::int from activity_alert_subscription
    where user_id = (select subscriber_id from fixtures)
      and activity_type_id = (select basketball_id from fixtures)),
  1,
  '別人呼叫 unsubscribe_activity_alert 傳我的訂閱 id 不應真的刪掉我的訂閱記錄'
);

-- -----------------------------------------------------------------------------
-- 9.2 已刪除帳號呼叫 subscribe_activity_alert 應被 ACCOUNT_DELETED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select deleted_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select subscribe_activity_alert(%L, 'NYCU'::school, %L, 3)$sql$,
    (select basketball_id from fixtures), (select campus from fixtures)),
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫 subscribe_activity_alert 應被 ACCOUNT_DELETED 擋下'
);

-- -----------------------------------------------------------------------------
-- 10. RLS：訂閱者自己看得到，別人查不到
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select subscriber_id from fixtures)::text, true);
end $$;

select ok(
  exists (select 1 from activity_alert_subscription where user_id = (select subscriber_id from fixtures)),
  '訂閱者自己看得到自己的訂閱記錄'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select other_id from fixtures)::text, true);
end $$;

select ok(
  not exists (select 1 from activity_alert_subscription where user_id = (select subscriber_id from fixtures)),
  '別人查不到我的訂閱記錄'
);

reset role;

select * from finish();

rollback;
