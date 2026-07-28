-- =============================================================================
-- pgTAP Test — 使用者主動封鎖 (block_user / unblock_user / fn_run_matching_engine
-- 的 user_block 檢查) — v1.17
--
-- 涵蓋：
-- 1. block_user 後，Matching Engine 不會把兩人撮合在一起（維持 REQUESTING）
-- 2. unblock_user 後，Matching Engine 恢復正常撮合
-- 3. block_user 冪等：重複呼叫不噴錯、不產生第二筆記錄
-- 4. block_user 拒絕自我封鎖 (CANNOT_BLOCK_SELF) 與不存在對象 (BLOCKED_USER_NOT_FOUND)
-- 5. RLS：被封鎖方 (`own_blocks_select`) 查不到封鎖記錄，封鎖方自己看得到
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(10);

-- -----------------------------------------------------------------------------
-- 0. Setup：A/B 兩筆相容的 Request（同校區、時段重疊、min=max=2）
-- -----------------------------------------------------------------------------

create temp table fixtures (
  a_id      uuid,
  b_id      uuid,
  a_req_id  uuid,
  b_req_id  uuid,
  campus    text
);
insert into fixtures default values;

-- 測試 5 之後會 `set local role authenticated` 來實測 RLS，該角色也要能讀
-- 這張 temp fixtures 表才能取得 a_id/b_id
grant select on fixtures to authenticated;

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := 'UB區';
  v_now         timestamptz := now();
  v_a_id        uuid := gen_random_uuid();
  v_b_id        uuid := gen_random_uuid();
  v_a_req       match_request;
  v_b_req       match_request;
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus, 'UB測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into auth.users (id, email) values
    (v_a_id, 'ub_a@nycu.edu.tw'), (v_b_id, 'ub_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_a_id, 'ub_a@nycu.edu.tw', 'NYCU', 'UB A', 'https://avatar.uba', 'UNDERGRAD', 'ub_a_ig'),
    (v_b_id, 'ub_b@nycu.edu.tw', 'NYCU', 'UB B', 'https://avatar.ubb', 'UNDERGRAD', 'ub_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_a_id, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_a_req.id, v_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_b_id, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_b_req.id, v_b_id, 'OWNER', 'JOINED');

  update fixtures set a_id = v_a_id, b_id = v_b_id, a_req_id = v_a_req.id, b_req_id = v_b_req.id, campus = v_campus;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. A 封鎖 B
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select a_id::text from fixtures), true);
end $$;

select lives_ok(
  $sql$select block_user((select b_id from fixtures), '測試理由')$sql$,
  'A 封鎖 B 應成功'
);

-- -----------------------------------------------------------------------------
-- 2. Matching Engine：A/B 彼此封鎖中，不應被撮合，維持 REQUESTING
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 0, '封鎖中：Matching Engine 不應把 A/B 撮合在一起');

select is(
  (select count(*)::int from match_request
    where id in ((select a_req_id from fixtures), (select b_req_id from fixtures))
      and status = 'REQUESTING'),
  2,
  '封鎖中：A/B 兩筆 Request 應維持 REQUESTING'
);

-- -----------------------------------------------------------------------------
-- 3. 重複呼叫 block_user 冪等：不噴錯、不產生第二筆
-- -----------------------------------------------------------------------------

select lives_ok(
  $sql$select block_user((select b_id from fixtures), '更新後的理由')$sql$,
  '重複封鎖同一人應冪等成功，不噴錯'
);

select is(
  (select count(*)::int from user_block
    where blocker_id = (select a_id from fixtures) and blocked_id = (select b_id from fixtures)),
  1,
  '重複呼叫 block_user 不應產生第二筆記錄'
);

-- -----------------------------------------------------------------------------
-- 4. 驗證錯誤：自我封鎖 / 封鎖不存在對象
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select block_user((select a_id from fixtures))$sql$,
  'INVALID_INPUT',
  '封鎖自己應被 CANNOT_BLOCK_SELF (INVALID_INPUT) 擋下'
);

select throws_ok(
  $sql$select block_user(gen_random_uuid())$sql$,
  'NOT_FOUND',
  '封鎖不存在的使用者應被 BLOCKED_USER_NOT_FOUND (NOT_FOUND) 擋下'
);

-- -----------------------------------------------------------------------------
-- 5. RLS：A 看得到自己的封鎖記錄，B（被封鎖方）永遠查不到
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select a_id::text from fixtures), true);
end $$;

select ok(
  exists (select 1 from user_block where blocked_id = (select b_id from fixtures)),
  'A（封鎖方）看得到自己封鎖 B 的記錄'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select b_id::text from fixtures), true);
end $$;

select ok(
  not exists (select 1 from user_block where blocker_id = (select a_id from fixtures)),
  'B（被封鎖方）永遠查不到自己被封鎖的記錄'
);

reset role;

-- -----------------------------------------------------------------------------
-- 6. unblock_user 後恢復正常撮合
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select a_id::text from fixtures), true);
  perform unblock_user((select b_id from fixtures));
end $$;

select is(fn_run_matching_engine(), 1, 'unblock 後：Matching Engine 應恢復正常撮合 A/B');

select * from finish();

rollback;
