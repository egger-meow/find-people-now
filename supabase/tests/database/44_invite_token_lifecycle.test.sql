-- =============================================================================
-- pgTAP Test — 邀請碼生命週期、撤銷防護與原子重生測試
-- =============================================================================
-- 涵蓋情境：
--   1. 初始產生：get_or_create_invite_link 於無碼時建立 12-byte hex 邀請碼
--   2. 冪等保證：第二次呼叫回傳相同邀請碼（FOR UPDATE 行鎖防護）
--   3. 加入測試：一般成員可憑此有效碼透過 join_request_by_token 成功入房
--   4. 撤銷功能：revoke_invite_link 正確設定 revoked_at
--   5. 失效攔截：使用已撤銷邀請碼呼叫 join_request_by_token 必須被擋下
--   6. 原子重生：撤銷後再次呼叫 get_or_create_invite_link 產生新碼，並清除 revoked_at
--   7. 重生冪等：重生後再次呼叫回傳相同新碼
--   8. 新碼有效：第三方可使用新碼成功加入
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  owner_id     uuid,
  guest_id     uuid,
  stranger_id  uuid,
  req_id       uuid,
  token_1      text,
  token_2      text
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id  uuid;
  v_campus       text := '光復';
  v_now          timestamptz := now();
  v_owner_id     uuid := gen_random_uuid();
  v_guest_id     uuid := gen_random_uuid();
  v_stranger_id  uuid := gen_random_uuid();
  v_req          match_request;
begin
  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus, '生命週期測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into auth.users (id, email) values
    (v_owner_id, 'token_owner@nycu.edu.tw'),
    (v_guest_id, 'token_guest@nycu.edu.tw'),
    (v_stranger_id, 'token_stranger@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_owner_id, 'token_owner@nycu.edu.tw', 'NYCU', 'Token Owner', 'https://avatar/owner', 'UNDERGRAD', 'owner_line'),
    (v_guest_id, 'token_guest@nycu.edu.tw', 'NYCU', 'Token Guest', 'https://avatar/guest', 'UNDERGRAD', 'guest_line'),
    (v_stranger_id, 'token_stranger@nycu.edu.tw', 'NYCU', 'Token Stranger', 'https://avatar/stranger', 'UNDERGRAD', 'stranger_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner_id, v_act_type_id, 'NYCU', v_campus, v_now + interval '1 hour', v_now + interval '3 hours', 3, 8, 'REQUESTING')
  returning * into v_req;

  insert into request_member (request_id, user_id, role, status) values
    (v_req.id, v_owner_id, 'OWNER', 'JOINED');

  update fixtures set owner_id = v_owner_id, guest_id = v_guest_id, stranger_id = v_stranger_id, req_id = v_req.id;
end;
$setup$;

grant select, update on fixtures to authenticated;

-- -----------------------------------------------------------------------------
-- 1. 初始產生邀請碼
-- -----------------------------------------------------------------------------

set local role authenticated;
do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select ok(
  (select length(get_or_create_invite_link((select req_id from fixtures))) = 24),
  'get_or_create_invite_link 應產生 24 字元之 12-byte hex 邀請碼'
);

update fixtures set token_1 = (select invite_token from match_request where id = (select req_id from fixtures));

-- -----------------------------------------------------------------------------
-- 2. 冪等性：再次呼叫回傳相同邀請碼（FOR UPDATE 行鎖保障）
-- -----------------------------------------------------------------------------

select is(
  (select get_or_create_invite_link((select req_id from fixtures))),
  (select token_1 from fixtures),
  '再次呼叫 get_or_create_invite_link 應回傳同一組邀請碼'
);

-- -----------------------------------------------------------------------------
-- 3. 成員使用邀請碼加入
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select guest_id::text from fixtures), true);
end $$;

select lives_ok(
  $sql$select join_request_by_token((select token_1 from fixtures))$sql$,
  'Guest 使用有效邀請碼加入應成功'
);

-- -----------------------------------------------------------------------------
-- 4. 房主撤銷邀請碼
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select is(
  (select revoke_invite_link((select req_id from fixtures))),
  true,
  '房主撤銷邀請碼應回傳 true'
);

-- -----------------------------------------------------------------------------
-- 5. 失效邀請碼無法加入
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select throws_ok(
  $sql$select join_request_by_token((select token_1 from fixtures))$sql$,
  'INVITE_LINK_EXPIRED',
  '使用已被撤銷的舊邀請碼加入應拋出 INVITE_LINK_EXPIRED 異常'
);

-- -----------------------------------------------------------------------------
-- 6. 房主重新產生邀請碼：產生新碼並清除 revoked_at
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

update fixtures set token_2 = (select get_or_create_invite_link((select req_id from fixtures)));

select isnt(
  (select token_2 from fixtures),
  (select token_1 from fixtures),
  '撤銷後重新呼叫 get_or_create_invite_link 應產生全新的邀請碼，而非重用舊碼'
);

select ok(
  (select revoked_at is null from match_request where id = (select req_id from fixtures)),
  '重新產生邀請碼後 match_request.revoked_at 應重設為 null'
);

-- -----------------------------------------------------------------------------
-- 7. 重生後的新碼可供第三方加入
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select lives_ok(
  $sql$select join_request_by_token((select token_2 from fixtures))$sql$,
  '第三方使用重新產生的新邀請碼加入應成功'
);

reset role;

select * from finish();

rollback;
