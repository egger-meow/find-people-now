-- =============================================================================
-- pgTAP Test — PC1 (respond_pending_confirmation 雙方皆 CONFIRMED) 應真的建立 Activity
--
-- 背景：commit_match 原本純粹依 v_total = count(request_member) 決定分支，這個計數
-- 在 Matching Engine 第一次呼叫、與雙方確認後 respond_pending_confirmation 重新呼叫
-- 之間完全沒變（仍然 <=2），導致第二次呼叫又走進「建立 pending_confirmation」分支，
-- 永遠不會真的建立 Activity（見 supabase/migrations/20260724122000_fix_commit_match_pc1.sql）。
-- 這是此前 64 個既有斷言從未覆蓋過的路徑：02_app_config_behavior.test.sql 只測過
-- confirm=false（拒絕）分支；01_happy_path_and_concurrency.test.sql 只用 raw insert
-- 直接塞一筆假的 PENDING 記錄測超時清理，都不是「兩個各 1 人的 Request 真的撮合、
-- 雙方都 confirm=true」這條完整路徑。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup：兩個各 1 人的 Request，走 commit_match 的 <=2 人 pending_confirmation 分支
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_a_id   uuid,
  user_b_id   uuid,
  act_type_id uuid,
  campus      text,
  req_a_id    uuid,
  req_b_id    uuid,
  pc_id       uuid
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
    (v_user_a_id, 'pc1_a@nycu.edu.tw'),
    (v_user_b_id, 'pc1_b@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig, contact_line) values
    (v_user_a_id, 'pc1_a@nycu.edu.tw', 'NYCU', 'PC1 A', 'https://avatar.pc1_a', 'MASTER', 'pc1_a_ig', 'pc1_a_line'),
    (v_user_b_id, 'pc1_b@nycu.edu.tw', 'NYCU', 'PC1 B', 'https://avatar.pc1_b', 'MASTER', 'pc1_b_ig', 'pc1_b_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

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

select is(
  (select count(*)::int from pending_confirmation
    where request_a_id = (select req_a_id from fixtures)
      and request_b_id = (select req_b_id from fixtures)),
  1,
  '第一次撮合後應恰好有 1 筆 pending_confirmation'
);

-- -----------------------------------------------------------------------------
-- 1. 雙方皆 respond_pending_confirmation(confirm=true) → PC1 應觸發，
--    直接建立 Activity，而不是再插入第二筆 pending_confirmation
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_a_id::text from fixtures), true);
  perform respond_pending_confirmation((select pc_id from fixtures), true);
end $$;

select is(
  (select status from pending_confirmation where id = (select pc_id from fixtures)),
  'PENDING',
  'User A 單獨確認後，pending_confirmation 應仍是 PENDING（尚未雙方皆確認）'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_b_id::text from fixtures), true);
  perform respond_pending_confirmation((select pc_id from fixtures), true);
end $$;

select is(
  (select status from pending_confirmation where id = (select pc_id from fixtures)),
  'CONFIRMED',
  'User B 也確認後，pending_confirmation 應轉為 CONFIRMED'
);

-- 關鍵斷言：不應該有第二筆 pending_confirmation 被插入（原 bug 的直接症狀）
select is(
  (select count(*)::int from pending_confirmation
    where request_a_id = (select req_a_id from fixtures)
      and request_b_id = (select req_b_id from fixtures)),
  1,
  'PC1 觸發後，pending_confirmation 仍應只有 1 筆（不應被重複插入第二筆）'
);

select ok(
  exists (
    select 1 from activity a
    where exists (
      select 1 from activity_member am
       where am.activity_id = a.id and am.user_id = (select user_a_id from fixtures)
    )
    and exists (
      select 1 from activity_member am
       where am.activity_id = a.id and am.user_id = (select user_b_id from fixtures)
    )
  ),
  'PC1 觸發後應真的建立一個包含雙方的 Activity'
);

select is(
  (select status from match_request where id = (select req_a_id from fixtures)),
  'MATCHED',
  'PC1 觸發後 req_a 狀態應轉為 MATCHED（而非停在 PENDING_CONFIRMATION）'
);

select is(
  (select status from match_request where id = (select req_b_id from fixtures)),
  'MATCHED',
  'PC1 觸發後 req_b 狀態應轉為 MATCHED（而非停在 PENDING_CONFIRMATION）'
);

select * from finish();

rollback;
