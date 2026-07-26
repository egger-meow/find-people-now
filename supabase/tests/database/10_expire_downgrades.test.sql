-- =============================================================================
-- pgTAP Test — fn_expire_downgrades() (docs/API.md §9「Downgrade 超時」，首次實作)
--
-- 涵蓋：expire_at 已過的 PENDING downgrade_request → TIMEOUT + 向所有
-- downgrade_consent 成員發送 DOWNGRADE_RESULT 通知；match_request 全程不被動
-- （STATE_MACHINE.md「Downgrade 子流程」：Downgrade 不改變 match_request.status）；
-- 尚未到期的 PENDING 不受影響。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(5);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  act_type_id  uuid,
  campus       text,
  -- req1: downgrade_request 已過期（expire_at < now()）
  req1_id      uuid, user1a_id uuid, user1b_id uuid, dg1_id uuid,
  -- req2: downgrade_request 尚未到期（對照組，不應被處理）
  req2_id      uuid, user2_id uuid, dg2_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_user1a uuid := gen_random_uuid();
  v_user1b uuid := gen_random_uuid();
  v_user2  uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_req1 match_request;
  v_req2 match_request;
  v_dg1  uuid;
  v_dg2  uuid;
begin
  insert into auth.users (id, email) values
    (v_user1a, 'ed_1a@nycu.edu.tw'), (v_user1b, 'ed_1b@nycu.edu.tw'), (v_user2, 'ed_2@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_user1a, 'ed_1a@nycu.edu.tw', 'NYCU', 'Ed 1a', 'https://avatar.ed_1a', 'MASTER', 'ed_1a_line'),
    (v_user1b, 'ed_1b@nycu.edu.tw', 'NYCU', 'Ed 1b', 'https://avatar.ed_1b', 'MASTER', 'ed_1b_line'),
    (v_user2, 'ed_2@nycu.edu.tw', 'NYCU', 'Ed 2', 'https://avatar.ed_2', 'MASTER', 'ed_2_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '學生活動中心', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user1a, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '15 minutes', 5, 5, true, 'REQUESTING')
  returning * into v_req1;
  insert into request_member (request_id, user_id, role, status) values
    (v_req1.id, v_user1a, 'OWNER', 'JOINED'), (v_req1.id, v_user1b, 'MEMBER', 'JOINED');
  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req1.id, 2, now() - interval '5 minutes', 'PENDING')
  returning id into v_dg1;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg1, v_user1a), (v_dg1, v_user1b);

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user2, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '2 minutes', 5, 5, true, 'REQUESTING')
  returning * into v_req2;
  insert into request_member (request_id, user_id, role, status) values (v_req2.id, v_user2, 'OWNER', 'JOINED');
  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req2.id, 2, now() + interval '5 minutes', 'PENDING')
  returning id into v_dg2;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg2, v_user2);

  update fixtures set
    act_type_id = v_act_type_id, campus = v_campus,
    req1_id = v_req1.id, user1a_id = v_user1a, user1b_id = v_user1b, dg1_id = v_dg1,
    req2_id = v_req2.id, user2_id = v_user2, dg2_id = v_dg2;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 執行 fn_expire_downgrades()
-- -----------------------------------------------------------------------------

select is(fn_expire_downgrades(), 1, 'fn_expire_downgrades 應恰好處理 1 筆已過期的 PENDING downgrade_request');

select is(
  (select status::text from downgrade_request where id = (select dg1_id from fixtures)),
  'TIMEOUT',
  '已過期的 downgrade_request 應轉為 TIMEOUT'
);

select is(
  (select status::text from match_request where id = (select req1_id from fixtures)),
  'REQUESTING',
  'Downgrade 超時不應改變 match_request.status（全程留在 REQUESTING，原門檻不變，SPEC §8）'
);

select is(
  (select count(*)::int from notification
    where event_type = 'DOWNGRADE_RESULT'
      and user_id in ((select user1a_id from fixtures), (select user1b_id from fixtures))
      and (payload->>'downgrade_request_id')::uuid = (select dg1_id from fixtures)
      and payload->>'status' = 'TIMEOUT'),
  2,
  '超時應向所有 downgrade_consent 成員各發一則 DOWNGRADE_RESULT(status=TIMEOUT) 通知'
);

select is(
  (select status::text from downgrade_request where id = (select dg2_id from fixtures)),
  'PENDING',
  '尚未到期的 downgrade_request 不應被處理'
);

select * from finish();

rollback;
