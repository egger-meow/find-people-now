-- =============================================================================
-- NYCU 在校生年限軟性提醒（v1.21）
-- 派生自使用者需求：僅 NYCU（NTHU 這輪不做），依 degree_level 設定門檻，
-- 純計算不落地存欄位（同 known_member_count/得票數的既有精神，見 ERD 設計備註 45）。
--
-- 解析規則：取信箱 local-part（@ 前面的部分）最後兩碼，若恰好是兩位數字，視為
-- 民國入學年（例如 mg09 → 109 年、cs15 → 115 年），不管前面代碼長度；解析不出
-- 這樣的數字（非兩位數字結尾、或 local part 不足兩碼）直接跳過此檢查，不視為錯誤。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. fn_parse_nycu_enrollment_year：抓不到回傳 null，plain SQL function 方便 pgTAP
--    直接測、不需要模擬 auth.uid()。
-- -----------------------------------------------------------------------------

create or replace function fn_parse_nycu_enrollment_year(p_email text)
returns int
language sql
immutable
as $$
  select case
    when right(split_part(p_email, '@', 1), 2) ~ '^[0-9]{2}$'
      then 100 + right(split_part(p_email, '@', 1), 2)::int
    else null
  end;
$$;

-- -----------------------------------------------------------------------------
-- 2. fn_seniority_reminder_needed：非 nycu 網域或解析失敗一律 false（跳過檢查，
--    不視為錯誤）。門檻：UNDERGRAD=6年、MASTER=4年、PHD=7年，
--    「現在年份 - 入學年 > 門檻」視為超過（>，不是 >=）。
-- -----------------------------------------------------------------------------

create or replace function fn_seniority_reminder_needed(p_email text, p_degree_level degree_level)
returns boolean
language plpgsql
immutable
as $$
declare
  v_enroll_year       int;
  v_current_roc_year  int;
  v_threshold         int;
begin
  if p_email !~* '@nycu\.edu\.tw$' then
    return false;
  end if;

  v_enroll_year := fn_parse_nycu_enrollment_year(p_email);
  if v_enroll_year is null then
    return false;
  end if;

  v_current_roc_year := extract(year from now())::int - 1911;
  v_threshold := case p_degree_level
    when 'UNDERGRAD' then 6
    when 'MASTER'    then 4
    when 'PHD'       then 7
  end;

  return (v_current_roc_year - v_enroll_year) > v_threshold;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. rpc: check_enrollment_reminder：complete_profile 送出前呼叫，degree_level
--    是表單當下選的值、此時 app_user 列可能還不存在，故不檢查 ACCOUNT_DELETED/
--    suspended_until（註冊當下這兩項檢查沒有意義）。
-- -----------------------------------------------------------------------------

create or replace function check_enrollment_reminder(
  p_degree_level degree_level
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email   text;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select email into v_email from auth.users where id = v_user_id;
  if v_email is null then
    raise exception using message = 'UNAUTHORIZED', detail = 'USER_EMAIL_NOT_FOUND';
  end if;

  return fn_seniority_reminder_needed(v_email, p_degree_level);
end;
$$;
