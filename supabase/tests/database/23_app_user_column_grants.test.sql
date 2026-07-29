-- =============================================================================
-- pgTAP Test — app_user column-level UPDATE grants (安全性修補回歸測試)
-- =============================================================================
-- 20260724125200_restrict_app_user_notification_column_grants.sql 收回了
-- `grant update on app_user to authenticated`（整欄授權），改成只放行
-- display_name/avatar_url/gender/bio/contact_ig/contact_line/contact_discord/
-- onboarding_seen_at 八個欄位。根因是舊的整欄授權讓任何被停權中的使用者可以
-- 自己 PATCH app_user.suspended_until 清空，完全繞過「連續 3 次 No-show
-- 停權 7 天」的懲罰機制，且完全不需要碰任何 RPC——這是先前沒有測試覆蓋的
-- 安全性缺口，這裡補上。
--
-- 兩個方向都要驗證：(1) 收斂沒有漏——suspended_until 仍然寫不進去；
-- (2) 收斂沒有誤傷——display_name/avatar_url 這類前端本來就該能直接改的
-- 欄位仍然正常可寫。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(3);

-- -----------------------------------------------------------------------------
-- 0. Setup — 一個目前正被停權中的使用者（suspended_until 在未來）。
-- -----------------------------------------------------------------------------

create temp table fixtures (suspended_user_id uuid);
insert into fixtures default values;

do $setup$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_id, 'acg_suspended@nycu.edu.tw');

  insert into app_user (
    id, email, school, display_name, avatar_url, degree_level, contact_line, suspended_until
  ) values (
    v_id, 'acg_suspended@nycu.edu.tw', 'NYCU', 'ACG Suspended', 'https://avatar.acg_suspended',
    'UNDERGRAD', 'acg_suspended_line', now() + interval '7 days'
  );

  update fixtures set suspended_user_id = v_id;
end;
$setup$;

grant select on fixtures to authenticated;

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select suspended_user_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 停權中使用者不應能直接 PATCH 自己的 suspended_until 來解除停權
--    （column-level grant 已不含 suspended_until，應被 42501 擋下）。
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$update app_user set suspended_until = null where id = %L$sql$,
    (select suspended_user_id from fixtures)),
  '42501',
  'permission denied for table app_user',
  '停權中使用者直接 UPDATE app_user.suspended_until 應被欄位授權擋下（42501）'
);

-- -----------------------------------------------------------------------------
-- 2. 同一使用者仍然能正常更新 display_name / avatar_url——確認收斂沒有
--    誤傷真正該開放的欄位。
-- -----------------------------------------------------------------------------

update app_user
  set display_name = 'ACG New Name', avatar_url = 'https://avatar.acg_new'
  where id = (select suspended_user_id from fixtures);

select is(
  (select display_name || '|' || avatar_url from app_user where id = (select suspended_user_id from fixtures)),
  'ACG New Name|https://avatar.acg_new',
  '停權中使用者仍應能正常更新 display_name / avatar_url'
);

-- -----------------------------------------------------------------------------
-- 3. suspended_until 應完全沒被上面任何操作動到，仍是原本的未來時間。
-- -----------------------------------------------------------------------------

select ok(
  (select suspended_until > now() from app_user where id = (select suspended_user_id from fixtures)),
  'suspended_until 應維持原本的停權時間，未被第 1/2 步的操作清空或改動'
);

reset role;

select * from finish();

rollback;
