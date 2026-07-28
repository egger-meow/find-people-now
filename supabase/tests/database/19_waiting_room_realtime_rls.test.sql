-- =============================================================================
-- pgTAP Test — 等待室 Realtime 相關 backend 修復回歸測試
-- =============================================================================
-- 涵蓋這輪（配對頁+等待室前端 round 1）發現並修掉的兩個既有 bug，補上獨立的
-- pgTAP 覆蓋，不再只靠 Flutter 整合測試間接驗證：
--   1. 20260724124900_fix_request_member_rls_recursion.sql
--      request_member 的 my_request_members_select policy 曾經自我參照造成
--      infinite recursion (42P17) —— 用 `set local role authenticated`
--      （比照 05_propose_location.test.sql 的手法）真的以 authenticated 角色
--      查詢，確保會踩到 fn_is_request_member 那個分支（查詢「別人那筆」而非
--      自己那筆才會真的觸發舊版的遞迴）。
--   2. 20260724125000_enable_pgcrypto.sql /
--      20260724125100_fix_invite_token_search_path.sql
--      get_or_create_invite_link 曾經因為 search_path 漏掉 extensions schema
--      導致 gen_random_bytes 解析不到 —— 真的呼叫一次，確認會成功產生 token
--      （而非只測失敗路徑），並確認冪等（第二次呼叫回傳已存的同一個 token）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(6);

-- -----------------------------------------------------------------------------
-- 0. Setup — 一筆 REQUESTING 的 match_request，owner + 一名一般成員，外加一個
--    完全無關的陌生人
-- -----------------------------------------------------------------------------

create temp table fixtures (
  owner_id     uuid,
  member_id    uuid,
  stranger_id  uuid,
  req_id       uuid,
  first_token  text
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id  uuid;
  v_campus       text := 'WR測試區';
  v_now          timestamptz := now();
  v_owner_id     uuid := gen_random_uuid();
  v_member_id    uuid := gen_random_uuid();
  v_stranger_id  uuid := gen_random_uuid();
  v_req          match_request;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus, 'WR測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into auth.users (id, email) values
    (v_owner_id, 'wr_owner@nycu.edu.tw'),
    (v_member_id, 'wr_member@nycu.edu.tw'),
    (v_stranger_id, 'wr_stranger@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_owner_id, 'wr_owner@nycu.edu.tw', 'NYCU', 'WR Owner', 'https://avatar.wr_owner', 'MASTER', 'wr_owner_line'),
    (v_member_id, 'wr_member@nycu.edu.tw', 'NYCU', 'WR Member', 'https://avatar.wr_member', 'MASTER', 'wr_member_line'),
    (v_stranger_id, 'wr_stranger@nycu.edu.tw', 'NYCU', 'WR Stranger', 'https://avatar.wr_stranger', 'MASTER', 'wr_stranger_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner_id, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 12, 'REQUESTING')
  returning * into v_req;

  insert into request_member (request_id, user_id, role, status) values
    (v_req.id, v_owner_id, 'OWNER', 'JOINED'),
    (v_req.id, v_member_id, 'MEMBER', 'JOINED');

  update fixtures set owner_id = v_owner_id, member_id = v_member_id, stranger_id = v_stranger_id, req_id = v_req.id;
end;
$setup$;

-- 測試會 `set local role authenticated` 真的切換角色實測 RLS，該角色也要能讀
-- 這張 temp fixtures 表（比照 05_propose_location.test.sql）；這裡還額外需要
-- update 權限，因為第 3 段會在 authenticated 角色下把 first_token 寫回 fixtures
grant select, update on fixtures to authenticated;

-- -----------------------------------------------------------------------------
-- 1. RLS 不再無限遞迴 — owner 查 request_member 應該能查到「別人那筆」
--    （member 的 JOINED 列），這正是舊版 my_request_members_select 會炸出
--    infinite recursion 的分支（自己那筆用 user_id = auth.uid() 就過了，不會
--    踩到遞迴；查詢同團隊友那筆才會真的呼叫 fn_is_request_member）
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select lives_ok(
  $sql$select 1 from request_member where request_id = (select req_id from fixtures)$sql$,
  'owner 查詢 request_member（含隊友那筆）不應觸發 infinite recursion (42P17)'
);

select is(
  (select count(*)::int from request_member where request_id = (select req_id from fixtures)),
  2,
  'owner 應該能看到自己團隊裡的兩筆 request_member（自己 + 隊友）'
);

-- -----------------------------------------------------------------------------
-- 2. RLS 仍然正確擋掉非成員 — 陌生人不應該看到任何一筆
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select is(
  (select count(*)::int from request_member where request_id = (select req_id from fixtures)),
  0,
  '非成員的陌生人不應該看到這個 Request 的任何 request_member 列'
);

-- -----------------------------------------------------------------------------
-- 3. get_or_create_invite_link 真的能成功產生 token（不是只測失敗路徑）
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select ok(
  (select length(get_or_create_invite_link((select req_id from fixtures))) > 0),
  'get_or_create_invite_link 應成功產生非空 token（曾經因 search_path 漏掉 extensions 而失敗）'
);

update fixtures set first_token = (select invite_token from match_request where id = (select req_id from fixtures));

select ok(
  (select first_token is not null from fixtures),
  'match_request.invite_token 欄位應該真的被寫入'
);

-- -----------------------------------------------------------------------------
-- 4. 冪等 — 第二次呼叫應回傳同一個已儲存的 token，不重新產生
-- -----------------------------------------------------------------------------

select is(
  (select get_or_create_invite_link((select req_id from fixtures))),
  (select first_token from fixtures),
  '第二次呼叫 get_or_create_invite_link 應回傳已儲存的相同 token（冪等）'
);

reset role;

select * from finish();

rollback;
