-- =============================================================================
-- pgTAP Test — leave_request (docs/API.md §3.5)
-- 之前完全沒有實作。涵蓋：非成員退出 (FORBIDDEN)、owner 不可用這個 endpoint 退出
-- (FORBIDDEN，應改用 cancel_request)、成員成功退出、重複退出 (FORBIDDEN)、
-- 配對成立後不可再退出 (REQUEST_NOT_OPEN，兩張狀態圖分界)。
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
  owner_id     uuid,
  member_id    uuid,
  outsider_id  uuid,
  member2_id   uuid,
  act_type_id  uuid,
  loc_id       uuid,
  req1_id      uuid,  -- REQUESTING, owner + member
  req2_id      uuid   -- MATCHED, owner + member2 (已配對成立，不可再退出)
);
insert into fixtures default values;

do $setup$
declare
  v_owner    uuid := gen_random_uuid();
  v_member   uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_member2  uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_loc_id      uuid;
  v_req1 match_request;
  v_req2 match_request;
begin
  insert into auth.users (id, email) values
    (v_owner, 'lv_owner@nycu.edu.tw'), (v_member, 'lv_member@nycu.edu.tw'),
    (v_outsider, 'lv_outsider@nycu.edu.tw'), (v_member2, 'lv_member2@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_owner, 'lv_owner@nycu.edu.tw', 'NYCU', 'Lv Owner', 'https://avatar.lv_owner', 'MASTER', 'lv_owner_line'),
    (v_member, 'lv_member@nycu.edu.tw', 'NYCU', 'Lv Member', 'https://avatar.lv_member', 'MASTER', 'lv_member_line'),
    (v_outsider, 'lv_outsider@nycu.edu.tw', 'NYCU', 'Lv Outsider', 'https://avatar.lv_outsider', 'MASTER', 'lv_outsider_line'),
    (v_member2, 'lv_member2@nycu.edu.tw', 'NYCU', 'Lv Member2', 'https://avatar.lv_member2', 'MASTER', 'lv_member2_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;
  insert into location (school, name, is_active) values ('NYCU', '第二餐廳前', true)
    on conflict (school, name) do update set is_active = true;
  select id into v_loc_id from location where school = 'NYCU' and name = '第二餐廳前';

  -- req1: REQUESTING，owner + member（模擬 member 透過邀請連結加入）
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_req1;
  insert into request_member (request_id, user_id, role, status) values
    (v_req1.id, v_owner, 'OWNER', 'JOINED'), (v_req1.id, v_member, 'MEMBER', 'JOINED');

  -- req2: 已配對成立 (MATCHED)，owner + member2
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning * into v_req2;
  insert into request_member (request_id, user_id, role, status) values
    (v_req2.id, v_owner, 'OWNER', 'JOINED'), (v_req2.id, v_member2, 'MEMBER', 'JOINED');

  update fixtures set
    owner_id = v_owner, member_id = v_member, outsider_id = v_outsider, member2_id = v_member2,
    act_type_id = v_act_type_id, loc_id = v_loc_id, req1_id = v_req1.id, req2_id = v_req2.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 非成員呼叫 leave_request 應被 FORBIDDEN 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select leave_request(%L)$sql$, (select req1_id from fixtures)),
  'FORBIDDEN',
  '非成員呼叫 leave_request 應被 FORBIDDEN 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. owner 呼叫 leave_request 應被 FORBIDDEN 擋下（應改用 cancel_request）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select leave_request(%L)$sql$, (select req1_id from fixtures)),
  'FORBIDDEN',
  'owner 呼叫 leave_request 應被 FORBIDDEN 擋下（owner 應改用 cancel_request）'
);

-- -----------------------------------------------------------------------------
-- 3. member 成功退出 — request_member.status 應變為 LEFT
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member_id::text from fixtures), true);
  perform leave_request((select req1_id from fixtures));
end $$;

select is(
  (select status::text from request_member
    where request_id = (select req1_id from fixtures) and user_id = (select member_id from fixtures)),
  'LEFT',
  'member 呼叫 leave_request 後 request_member.status 應變為 LEFT'
);

-- -----------------------------------------------------------------------------
-- 4. 已經 LEFT 的成員重複呼叫應被 FORBIDDEN 擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select leave_request(%L)$sql$, (select req1_id from fixtures)),
  'FORBIDDEN',
  '已經 LEFT 的成員重複呼叫 leave_request 應被 FORBIDDEN 擋下'
);

-- -----------------------------------------------------------------------------
-- 5. 已配對成立 (MATCHED) 的 Request，成員不可再用 leave_request 退出
--    （應改走 Activity 側的 cancel_activity_participation，兩張狀態圖分界）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member2_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select leave_request(%L)$sql$, (select req2_id from fixtures)),
  'REQUEST_NOT_OPEN',
  '已配對成立的 Request 不可再用 leave_request 退出，應為 REQUEST_NOT_OPEN'
);

select * from finish();

rollback;
