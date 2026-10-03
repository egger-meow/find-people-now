-- =============================================================================
-- pgTAP Test — get_request_member_profiles (docs/API.md §3.9)
-- =============================================================================
-- 涵蓋情境：
--   1. 未登入呼叫拋出 UNAUTHORIZED
--   2. 不存在的 Request 拋出 NOT_FOUND
--   3. 非該 Request 的陌生人呼叫拋出 NOT_REQUEST_MEMBER
--   4. 房內成員呼叫，成功回傳同房間活躍成員數為 2（排除 LEFT 者）
--   5. 回傳順序為發起人 (OWNER) 優先，且揭露 display_name 與 avatar_url
--   6. 第二位成員為 MEMBER，且含真實暱稱
--
-- 執行：`supabase test db`
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  owner_id     uuid,
  member_id    uuid,
  left_user_id uuid,
  stranger_id  uuid,
  req_id       uuid
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id  uuid;
  v_campus       text := '光復';
  v_now          timestamptz := now();
  v_owner_id     uuid := gen_random_uuid();
  v_member_id    uuid := gen_random_uuid();
  v_left_user_id uuid := gen_random_uuid();
  v_stranger_id  uuid := gen_random_uuid();
  v_req          match_request;
begin
  select id into v_act_type_id from activity_type limit 1;
  select campus into v_campus from location where school = 'NYCU' and is_active = true limit 1;
  if v_campus is null then
    v_campus := 'Guangfu';
    insert into location (school, campus, name, is_active) values
      ('NYCU', v_campus, 'Member Profile Test Location', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;
  end if;

  insert into auth.users (id, email) values
    (v_owner_id, 'rmp_owner@nycu.edu.tw'),
    (v_member_id, 'rmp_member@nycu.edu.tw'),
    (v_left_user_id, 'rmp_left@nycu.edu.tw'),
    (v_stranger_id, 'rmp_stranger@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_owner_id, 'rmp_owner@nycu.edu.tw', 'NYCU', 'Owner Ming', 'https://avatar/owner.png', 'UNDERGRAD', 'owner_line'),
    (v_member_id, 'rmp_member@nycu.edu.tw', 'NYCU', 'Friend Hua', 'https://avatar/member.png', 'UNDERGRAD', 'member_line'),
    (v_left_user_id, 'rmp_left@nycu.edu.tw', 'NYCU', 'Left User', 'https://avatar/left.png', 'UNDERGRAD', 'left_line'),
    (v_stranger_id, 'rmp_stranger@nycu.edu.tw', 'NYCU', 'Stranger', 'https://avatar/stranger.png', 'UNDERGRAD', 'stranger_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner_id, v_act_type_id, 'NYCU', v_campus, v_now + interval '1 hour', v_now + interval '3 hours', 2, 4, 'REQUESTING')
  returning * into v_req;

  insert into request_member (request_id, user_id, role, status, created_at) values
    (v_req.id, v_owner_id, 'OWNER', 'JOINED', v_now),
    (v_req.id, v_member_id, 'MEMBER', 'JOINED', v_now + interval '1 minute'),
    (v_req.id, v_left_user_id, 'MEMBER', 'LEFT', v_now + interval '2 minutes');

  update fixtures set
    owner_id = v_owner_id,
    member_id = v_member_id,
    left_user_id = v_left_user_id,
    stranger_id = v_stranger_id,
    req_id = v_req.id;
end;
$setup$;

grant select on fixtures to authenticated, anon;

-- -----------------------------------------------------------------------------
-- 1. 未登入呼叫拋出 UNAUTHORIZED
-- -----------------------------------------------------------------------------

set local role anon;
select throws_ok(
  format('select get_request_member_profiles(%L::uuid)', (select req_id from fixtures)),
  'UNAUTHORIZED',
  '未登入者呼叫 get_request_member_profiles 應拋出 UNAUTHORIZED'
);

-- -----------------------------------------------------------------------------
-- 2. 不存在的 Request 拋出 NOT_FOUND
-- -----------------------------------------------------------------------------

set local role authenticated;
do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select throws_ok(
  'select get_request_member_profiles(gen_random_uuid())',
  'NOT_FOUND',
  '查詢不存在之 request_id 應拋出 NOT_FOUND'
);

-- -----------------------------------------------------------------------------
-- 3. 非該 Request 的陌生人呼叫拋出 NOT_REQUEST_MEMBER (防肉搜/盲配邊界)
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select throws_ok(
  format('select get_request_member_profiles(%L::uuid)', (select req_id from fixtures)),
  'NOT_REQUEST_MEMBER',
  '非該房間成員呼叫應被阻擋並拋出 NOT_REQUEST_MEMBER'
);

-- -----------------------------------------------------------------------------
-- 4. 房內成員呼叫成功取得名單長度為 2（排除 LEFT 者）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member_id::text from fixtures), true);
end $$;

select is(
  jsonb_array_length(get_request_member_profiles((select req_id from fixtures))),
  2,
  '已入房成員呼叫應回傳 2 位活躍成員（排除已退出者）'
);

-- -----------------------------------------------------------------------------
-- 5. 首位成員必須為 OWNER（Owner Ming）且含真實暱稱與頭像
-- -----------------------------------------------------------------------------

select is(
  (select elem->>'display_name'
     from jsonb_array_elements(get_request_member_profiles((select req_id from fixtures))) with ordinality as t(elem, idx)
    where idx = 1),
  'Owner Ming',
  '第一位成員應為 OWNER Owner Ming'
);

select is(
  (select elem->>'avatar_url'
     from jsonb_array_elements(get_request_member_profiles((select req_id from fixtures))) with ordinality as t(elem, idx)
    where idx = 1),
  'https://avatar/owner.png',
  '發起人應正確揭露其 avatar_url'
);

-- -----------------------------------------------------------------------------
-- 6. 第二位成員為 MEMBER（Friend Hua）且含真實暱稱
-- -----------------------------------------------------------------------------

select is(
  (select elem->>'display_name'
     from jsonb_array_elements(get_request_member_profiles((select req_id from fixtures))) with ordinality as t(elem, idx)
    where idx = 2),
  'Friend Hua',
  '第二位成員應為 MEMBER Friend Hua'
);

rollback;
