-- =============================================================================
-- complete_profile：新增可選參數 p_default_campus（v1.32）
-- =============================================================================
-- 註冊畫面（complete_profile_screen.dart）在校區清單有 2 個以上選項時，讓
-- 使用者選一次「主要校區」隨這次呼叫一起送出；只有 1 個選項時前端直接靜默
-- 帶入，不多問。
--
-- 關鍵：`on conflict (id) do update` 這條路徑同時也是 edit_profile_screen.dart
-- 編輯個人資料時會重複呼叫的路徑，而編輯個人資料表單完全不觸碰校區——若
-- 直接 `default_campus = excluded.default_campus`，每次使用者改個人簡介
-- 之類的欄位都會把 p_default_campus（該次呼叫沒帶、值是 null）覆寫回去，
-- 悄悄清空使用者原本設定好的預設校區。改用
-- `coalesce(excluded.default_campus, app_user.default_campus)`：本次有帶值
-- 才覆寫，沒帶就維持原值不動。
--
-- 加新參數必須先 drop 掉舊的 9-參數簽名——PostgreSQL 的 CREATE OR REPLACE
-- 不能單靠改參數列表「替換」既有函式，多一個參數（即使有 default）會變成
-- 新增一個 overload 而不是取代，任何只帶 9 個參數呼叫的既有呼叫端會在新舊
-- 兩個 overload 之間產生「function ... is not unique」的歧義錯誤（同一個坑
-- v1.30 在 propose_activity_location / vote_activity_location 已踩過一次）。

drop function if exists complete_profile(text, text, degree_level, text, text, text, text, text, text);

create or replace function complete_profile(
  p_display_name     text,
  p_avatar_url       text,
  p_degree_level     degree_level,
  p_department       text default null,
  p_gender           text default null,
  p_bio              text default null,
  p_contact_ig       text default null,
  p_contact_line     text default null,
  p_contact_discord  text default null,
  p_default_campus   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_email    text;
  v_school   school;
  v_result   jsonb;
begin
  -- 驗證登入身分
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  -- 檢查停權狀態
  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  -- 驗證硬性門檻
  if p_display_name is null or trim(p_display_name) = '' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'DISPLAY_NAME_REQUIRED';
  end if;

  if p_avatar_url is null or trim(p_avatar_url) = '' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'AVATAR_URL_REQUIRED';
  end if;

  if p_degree_level is null then
    raise exception using message = 'DEGREE_LEVEL_REQUIRED';
  end if;

  if p_contact_ig is null and p_contact_line is null and p_contact_discord is null then
    raise exception using message = 'NO_CONTACT_METHOD', detail = 'AT_LEAST_ONE_CONTACT_REQUIRED';
  end if;

  -- 從 auth.users 取得 email 並推導學校（SPEC §2：不讓使用者自選）
  select email into v_email
    from auth.users
   where id = v_user_id;

  if v_email is null then
    raise exception using message = 'UNAUTHORIZED', detail = 'USER_EMAIL_NOT_FOUND';
  end if;

  if v_email ~* '@nycu\.edu\.tw$' then
    v_school := 'NYCU';
  elsif v_email ~* '@nthu\.edu\.tw$' then
    v_school := 'NTHU';
  else
    raise exception using message = 'INVALID_EMAIL_DOMAIN';
  end if;

  -- Upsert 到 app_user
  insert into app_user (
    id, email, school, display_name, avatar_url, degree_level,
    department, gender, bio, contact_ig, contact_line, contact_discord, default_campus
  ) values (
    v_user_id, v_email, v_school, p_display_name, p_avatar_url, p_degree_level,
    p_department, p_gender, p_bio, p_contact_ig, p_contact_line, p_contact_discord, p_default_campus
  )
  on conflict (id) do update set
    display_name    = excluded.display_name,
    avatar_url      = excluded.avatar_url,
    degree_level    = excluded.degree_level,
    department      = excluded.department,
    gender          = excluded.gender,
    bio             = excluded.bio,
    contact_ig      = excluded.contact_ig,
    contact_line    = excluded.contact_line,
    contact_discord = excluded.contact_discord,
    default_campus  = coalesce(excluded.default_campus, app_user.default_campus);

  select to_jsonb(u.*) into v_result
    from app_user u
   where u.id = v_user_id;

  return v_result;
end;
$$;
