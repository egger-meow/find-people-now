-- =============================================================================
-- pgTAP Test — NYCU 在校生年限軟性提醒 (fn_seniority_reminder_needed /
-- fn_parse_nycu_enrollment_year / check_enrollment_reminder) — v1.21
--
-- 涵蓋：
-- 1. UNDERGRAD/MASTER/PHD 各自門檻超過時正確觸發（true）
-- 2. UNDERGRAD/MASTER/PHD 各自門檻剛好等於（不算超過，> 不是 >=）不觸發（false）
-- 3. 非 @nycu.edu.tw 網域（含 @nthu.edu.tw）一律跳過，回 false
-- 4. 信箱格式無法解析出兩位數字結尾，跳過，回 false
-- 5. end-to-end：真的模擬登入呼叫 check_enrollment_reminder RPC
--
-- 全部門檻計算依「目前 ROC 年份」動態產生測試信箱，不寫死西元/民國年份，
-- 避免測試隨時間推移失效。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(9);

-- -----------------------------------------------------------------------------
-- 0. Setup：依目前 ROC 年份動態產生各門檻情境的測試信箱
-- -----------------------------------------------------------------------------

create temp table fixtures (
  email_undergrad_over   text,  -- diff = 7 > 6 門檻
  email_undergrad_at     text,  -- diff = 6 = 門檻，不算超過
  email_master_over      text,  -- diff = 5 > 4 門檻
  email_master_at        text,  -- diff = 4 = 門檻
  email_phd_over         text,  -- diff = 8 > 7 門檻
  email_phd_at           text,  -- diff = 7 = 門檻
  email_nthu_over        text,  -- 跟 undergrad_over 同樣的數字結尾，但網域是 nthu
  reminder_user_id       uuid
);
insert into fixtures default values;

grant select on fixtures to authenticated;

do $setup$
declare
  v_roc int := extract(year from now())::int - 1911;
  v_reminder_user_id uuid := gen_random_uuid();
begin
  update fixtures set
    email_undergrad_over = format('sr_ug_over%s@nycu.edu.tw', to_char((v_roc - 7) - 100, 'FM00')),
    email_undergrad_at   = format('sr_ug_at%s@nycu.edu.tw',   to_char((v_roc - 6) - 100, 'FM00')),
    email_master_over    = format('sr_ma_over%s@nycu.edu.tw', to_char((v_roc - 5) - 100, 'FM00')),
    email_master_at      = format('sr_ma_at%s@nycu.edu.tw',   to_char((v_roc - 4) - 100, 'FM00')),
    email_phd_over       = format('sr_phd_over%s@nycu.edu.tw', to_char((v_roc - 8) - 100, 'FM00')),
    email_phd_at         = format('sr_phd_at%s@nycu.edu.tw',   to_char((v_roc - 7) - 100, 'FM00')),
    email_nthu_over      = format('sr_nthu_over%s@nthu.edu.tw', to_char((v_roc - 7) - 100, 'FM00')),
    reminder_user_id     = v_reminder_user_id;

  insert into auth.users (id, email) values
    (v_reminder_user_id, (select email_undergrad_over from fixtures));
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_reminder_user_id, (select email_undergrad_over from fixtures), 'NYCU', 'SR Reminder', 'https://avatar.srreminder', 'UNDERGRAD', 'sr_reminder_ig');
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 各學制超過門檻應觸發（true）
-- -----------------------------------------------------------------------------

select is(
  fn_seniority_reminder_needed((select email_undergrad_over from fixtures), 'UNDERGRAD'),
  true,
  'UNDERGRAD 超過 6 年門檻應觸發提醒'
);

select is(
  fn_seniority_reminder_needed((select email_master_over from fixtures), 'MASTER'),
  true,
  'MASTER 超過 4 年門檻應觸發提醒'
);

select is(
  fn_seniority_reminder_needed((select email_phd_over from fixtures), 'PHD'),
  true,
  'PHD 超過 7 年門檻應觸發提醒'
);

-- -----------------------------------------------------------------------------
-- 2. 各學制剛好等於門檻不算超過（false，> 不是 >=）
-- -----------------------------------------------------------------------------

select is(
  fn_seniority_reminder_needed((select email_undergrad_at from fixtures), 'UNDERGRAD'),
  false,
  'UNDERGRAD 剛好等於 6 年門檻不算超過，不應觸發'
);

select is(
  fn_seniority_reminder_needed((select email_master_at from fixtures), 'MASTER'),
  false,
  'MASTER 剛好等於 4 年門檻不算超過，不應觸發'
);

select is(
  fn_seniority_reminder_needed((select email_phd_at from fixtures), 'PHD'),
  false,
  'PHD 剛好等於 7 年門檻不算超過，不應觸發'
);

-- -----------------------------------------------------------------------------
-- 3. 非 nycu 網域一律跳過
-- -----------------------------------------------------------------------------

select is(
  fn_seniority_reminder_needed((select email_nthu_over from fixtures), 'UNDERGRAD'),
  false,
  '非 @nycu.edu.tw 網域（含 @nthu.edu.tw）一律跳過此檢查'
);

-- -----------------------------------------------------------------------------
-- 4. 信箱格式無法解析出兩位數字結尾，跳過
-- -----------------------------------------------------------------------------

select is(
  fn_seniority_reminder_needed('nodigits@nycu.edu.tw', 'UNDERGRAD'),
  false,
  '信箱格式無法解析出兩位數字結尾應跳過檢查，不視為錯誤'
);

-- -----------------------------------------------------------------------------
-- 5. end-to-end：真的模擬登入呼叫 check_enrollment_reminder RPC
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select reminder_user_id::text from fixtures), true);
end $$;

select is(
  check_enrollment_reminder('UNDERGRAD'::degree_level),
  true,
  'check_enrollment_reminder RPC 應正確從 auth.users.email 讀出並得到一致結果'
);

select * from finish();

rollback;
