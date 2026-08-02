-- =============================================================================
-- pgTAP Test — complete_profile p_default_campus (v1.32)
-- =============================================================================
-- 覆蓋 20260803130100_app_user_default_campus_rpc.sql 的核心行為：
-- 第一次呼叫（等同註冊）帶入的校區要存進去；之後編輯個人資料（如
-- edit_profile_screen.dart）重複呼叫但不帶校區時，不能把先前存好的值洗掉
-- （coalesce 邏輯）；帶新校區時要能正常覆蓋（如 create_request_screen.dart
-- 送出時回寫「最近使用」的校區）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(4);

-- -----------------------------------------------------------------------------
-- 0. Setup — 一個尚未完成 profile 的 NYCU 使用者。
-- -----------------------------------------------------------------------------

create temp table fixtures (user_id uuid);
insert into fixtures default values;

do $setup$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_id, 'dc_user@nycu.edu.tw');
  update fixtures set user_id = v_id;
end;
$setup$;

grant select on fixtures to authenticated;

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 第一次呼叫（等同註冊）帶入 p_default_campus，應直接寫入。
-- -----------------------------------------------------------------------------

select complete_profile(
  p_display_name    := 'DC User',
  p_avatar_url      := 'https://avatar.dc_user',
  p_degree_level    := 'UNDERGRAD',
  p_contact_line    := 'dc_user_line',
  p_default_campus  := '光復'
);

select is(
  (select default_campus from app_user where id = (select user_id from fixtures)),
  '光復',
  '第一次呼叫（註冊）帶入的 p_default_campus 應直接寫入 app_user.default_campus'
);

-- -----------------------------------------------------------------------------
-- 2. 之後編輯個人資料重複呼叫，但不帶 p_default_campus（比照
--    edit_profile_screen.dart 完全不碰校區欄位）——不應把已存的值洗掉。
-- -----------------------------------------------------------------------------

select complete_profile(
  p_display_name    := 'DC User Renamed',
  p_avatar_url      := 'https://avatar.dc_user',
  p_degree_level    := 'UNDERGRAD',
  p_contact_line    := 'dc_user_line'
);

select is(
  (select display_name || '|' || default_campus from app_user where id = (select user_id from fixtures)),
  'DC User Renamed|光復',
  '重複呼叫但未帶 p_default_campus 不應清空已存的 default_campus（coalesce 保留原值）'
);

-- -----------------------------------------------------------------------------
-- 3. 帶新的校區值，應正常覆蓋（比照 create_request_screen.dart 送出時回寫
--    「最近使用」的校區）。
-- -----------------------------------------------------------------------------

select complete_profile(
  p_display_name    := 'DC User Renamed',
  p_avatar_url      := 'https://avatar.dc_user',
  p_degree_level    := 'UNDERGRAD',
  p_contact_line    := 'dc_user_line',
  p_default_campus  := '博愛'
);

select is(
  (select default_campus from app_user where id = (select user_id from fixtures)),
  '博愛',
  '帶新的 p_default_campus 應正常覆蓋既有值'
);

-- -----------------------------------------------------------------------------
-- 4. 從沒帶過 p_default_campus 的全新使用者，欄位應維持 null（不強迫一定要
--    有值——只有 2 個以上校區選項時前端才會要求使用者選）。
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
end $$;

reset role;

do $setup2$
declare
  v_id uuid := (select current_setting('request.jwt.claim.sub', true))::uuid;
begin
  insert into auth.users (id, email) values (v_id, 'dc_user2@nycu.edu.tw');
end;
$setup2$;

set local role authenticated;

select complete_profile(
  p_display_name    := 'DC User Two',
  p_avatar_url      := 'https://avatar.dc_user2',
  p_degree_level    := 'UNDERGRAD',
  p_contact_line    := 'dc_user2_line'
);

select is(
  (select default_campus from app_user
    where email = 'dc_user2@nycu.edu.tw'),
  null::text,
  '從未帶過 p_default_campus 的使用者，該欄位應維持 null'
);

reset role;

select * from finish();

rollback;
