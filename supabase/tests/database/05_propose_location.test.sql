-- =============================================================================
-- pgTAP Test — propose_location (docs/API.md §2.5, v1.10)
-- 涵蓋：成功提案 (PENDING + created_by 正確)、重複名稱 (DUPLICATE_LOCATION_NAME)、
-- 空白名稱 (INVALID_INPUT)、空白 campus (INVALID_INPUT，v1.11 新增 p_campus 參數)、
-- RLS 可見性（提案者看得到自己那筆 PENDING，其他人看不到）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(6);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  proposer_id  uuid,
  other_id     uuid
);
insert into fixtures default values;

do $setup$
declare
  v_proposer uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values
    (v_proposer, 'pl_proposer@nycu.edu.tw'), (v_other, 'pl_other@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_proposer, 'pl_proposer@nycu.edu.tw', 'NYCU', 'Pl Proposer', 'https://avatar.pl_proposer', 'MASTER', 'pl_proposer_line'),
    (v_other, 'pl_other@nycu.edu.tw', 'NYCU', 'Pl Other', 'https://avatar.pl_other', 'MASTER', 'pl_other_line');

  update fixtures set proposer_id = v_proposer, other_id = v_other;
end;
$setup$;

-- 測試 4/5 之後會 `set local role authenticated` 來實測 RLS，該角色也要能讀
-- 這張 temp fixtures 表才能取得 proposer_id/other_id
grant select on fixtures to authenticated;

-- -----------------------------------------------------------------------------
-- 1. 成功提案 — 應為 PENDING，created_by 為呼叫者本人
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select proposer_id::text from fixtures), true);
end $$;

select results_eq(
  format($sql$select status::text, created_by from propose_location(%L, 'NYCU', '光復')$sql$, 'pgTAP 測試地點 A'),
  format($sql$values ('PENDING', %L::uuid)$sql$, (select proposer_id from fixtures)),
  'propose_location 成功後應為 PENDING，created_by 為呼叫者本人'
);

-- -----------------------------------------------------------------------------
-- 2. 同校同名重複提案應被 DUPLICATE_LOCATION_NAME 擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select propose_location('pgTAP 測試地點 A', 'NYCU', '光復')$sql$,
  'DUPLICATE_LOCATION_NAME',
  '同校同名地點重複提案應被 DUPLICATE_LOCATION_NAME 擋下'
);

-- -----------------------------------------------------------------------------
-- 3. 空白名稱應被 INVALID_INPUT 擋下
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select propose_location('   ', 'NYCU', '光復')$sql$,
  'INVALID_INPUT',
  '空白名稱應被 INVALID_INPUT 擋下'
);

-- -----------------------------------------------------------------------------
-- 3b. 空白 campus 應被 INVALID_INPUT 擋下 (v1.11)
-- -----------------------------------------------------------------------------

select throws_ok(
  $sql$select propose_location('pgTAP 測試地點 B', 'NYCU', '  ')$sql$,
  'INVALID_INPUT',
  '空白 campus 應被 INVALID_INPUT 擋下 (v1.11)'
);

-- -----------------------------------------------------------------------------
-- 4. RLS：提案者自己看得到剛提的 PENDING 地點
-- -----------------------------------------------------------------------------
-- 這個連線用的是 postgres superuser，預設繞過 RLS，所以要 `set local role
-- authenticated` 真的切換角色才能實測 policy（比照 20260724120800_grants.sql
-- 授權給 authenticated 的權限），單靠 set_config jwt claim 不夠。

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select proposer_id::text from fixtures), true);
end $$;

select ok(
  exists (select 1 from location where school = 'NYCU' and name = 'pgTAP 測試地點 A'),
  '提案者可以看到自己剛提的 PENDING 地點'
);

-- -----------------------------------------------------------------------------
-- 5. RLS：其他使用者看不到別人提的 PENDING 地點
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select other_id::text from fixtures), true);
end $$;

select ok(
  not exists (select 1 from location where school = 'NYCU' and name = 'pgTAP 測試地點 A'),
  '其他使用者看不到別人提的 PENDING 地點'
);

reset role;

select * from finish();

rollback;
