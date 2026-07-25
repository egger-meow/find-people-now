-- =============================================================================
-- Phase 1 RPCs — Profile & Auth
-- 派生自 docs/SPEC.md §2、§12 及 docs/API.md §1
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: complete_profile
-- 完成/更新個人資料（註冊門檻驗證與自動學校判定）
-- -----------------------------------------------------------------------------

create or replace function complete_profile(
  p_display_name     text,
  p_avatar_url       text,
  p_degree_level     degree_level,
  p_department       text default null,
  p_gender           text default null,
  p_bio              text default null,
  p_contact_ig       text default null,
  p_contact_line     text default null,
  p_contact_discord  text default null
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
    department, gender, bio, contact_ig, contact_line, contact_discord
  ) values (
    v_user_id, v_email, v_school, p_display_name, p_avatar_url, p_degree_level,
    p_department, p_gender, p_bio, p_contact_ig, p_contact_line, p_contact_discord
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
    contact_discord = excluded.contact_discord;

  select to_jsonb(u.*) into v_result
    from app_user u
   where u.id = v_user_id;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: get_my_reliability
-- 查詢當前使用者的可信度等級與新人狀態 (SPEC §12)
-- -----------------------------------------------------------------------------

create or replace function get_my_reliability()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  return jsonb_build_object(
    'tier', fn_reliability_tier(v_user_id),
    'is_new_user', fn_is_new_user(v_user_id)
  );
end;
$$;
