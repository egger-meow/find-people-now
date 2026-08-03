-- =============================================================================
-- bio 從選填改為註冊硬性門檻 + avatar_url 擋自動產生佔位頭像（v1.33）
-- =============================================================================
-- 起因：使用者要求配對成立後的成員名單能點開更完整的個人檔案卡（照片＋自我
-- 介紹＋科系等），但 bio 一直是選填、沒有任何非空檢查（見 ERD.md 設計備註
-- 10：「跟 gender 同等級」），大量使用者根本沒填，檔案卡形同虛設。同一輪也
-- 決定頭像不能只是註冊畫面自動產生的 Dicebear 卡通頭像（見
-- complete_profile_screen.dart 的 _rerollAvatar()）——那雖然滿足現有
-- AVATAR_URL_REQUIRED 的「非空字串」檢查，但配對後彼此完全認不出人，違背
-- 這次要解決的「比較好認人」目的。
--
-- 做法比照 avatar_url 既有的兩層防護：DB 層 NOT NULL（防直接寫表繞過）+
-- RPC 層非空字串檢查（真正擋住的地方，NOT NULL 本身擋不住空字串）。
-- Dicebear 佔位頭像的擋法：整個 repo 唯一會產生「使用者沒有主動上傳」網址
-- 的來源就是 api.dicebear.com（見 avatar_upload.dart 的 pickAndUploadAvatar
-- 完全沒有這類自動產生邏輯，也沒有任何人臉辨識能力），直接擋這個網域即可，
-- 不需要導入任何 ML 依賴。
--
-- 這兩條新檢查跟既有的 AVATAR_URL_REQUIRED 一樣，掛在 complete_profile 這個
-- 註冊/編輯共用的 upsert 裡，所以會同時套用到編輯個人資料——現有使用者若
-- bio 還是空的、或頭像還是 Dicebear，下次存編輯個人資料時就會被要求補上，
-- 這是刻意的漸進式遷移，不是遺漏（RPC 結構上也沒辦法區分「這是第一次註冊
-- 還是編輯」）。
--
-- complete_profile 本次沒有新增/移除參數，簽名跟 20260803130100 完全相同，
-- 不需要 drop function（只有參數列表變動才需要 drop，見該檔案內註解）。
-- =============================================================================

-- bio 從 nullable 改 NOT NULL：先 backfill 既有 null 值，避免 SET NOT NULL 失敗。
update app_user set bio = '' where bio is null;

alter table app_user
  alter column bio set default '',
  alter column bio set not null;

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

  -- v1.33：擋自動產生的 Dicebear 佔位頭像，要求真人上傳的照片，方便配對後
  -- 彼此認出對方（見本檔案開頭說明）。
  if p_avatar_url ~* 'dicebear\.com' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'PLACEHOLDER_AVATAR_NOT_ALLOWED';
  end if;

  -- v1.33：bio 從選填改為硬性門檻。
  if p_bio is null or trim(p_bio) = '' then
    raise exception using message = 'PROFILE_INCOMPLETE', detail = 'BIO_REQUIRED';
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

-- delete_account 去識別化：bio 現在是 NOT NULL，原本清成 null 會違反約束，
-- 改清成空字串（跟 avatar_url 既有的去識別化寫法一致）。其餘邏輯完全不變，
-- 照抄 20260801160100_fix_delete_account_personal_text.sql 的最新定義。
create or replace function delete_account()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    return jsonb_build_object('success', true, 'already_deleted', true);
  end if;

  if not exists (select 1 from app_user where id = v_user_id) then
    return jsonb_build_object('success', true, 'had_profile', false);
  end if;

  update match_request
     set status = 'CANCELLED'
   where owner_id = v_user_id
     and status in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION');

  update request_member rm
     set status = 'LEFT'
   where rm.user_id = v_user_id
     and rm.status = 'JOINED'
     and exists (
       select 1 from match_request mr
        where mr.id = rm.request_id
          and mr.owner_id <> v_user_id
          and mr.status in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION')
     );

  update activity_member
     set status = 'CANCELLED'
   where user_id = v_user_id
     and status = 'JOINED'
     and activity_id in (select id from activity where status in ('MATCHED', 'ONGOING'));

  update activity_member
     set meeting_hint = null,
         vibe_tags    = null
   where user_id = v_user_id
     and (meeting_hint is not null or vibe_tags is not null);

  delete from notification where user_id = v_user_id;

  delete from match_history_avoidance where user_a_id = v_user_id or user_b_id = v_user_id;

  update app_user
     set email                    = 'deleted+' || v_user_id::text,
         display_name             = '已刪除的使用者',
         avatar_url                = '',
         gender                    = null,
         bio                       = '',
         department                = null,
         contact_ig                = null,
         contact_line              = '[已刪除帳號]',
         contact_discord           = null,
         suspended_until           = null,
         next_request_allowed_at   = null,
         deleted_at                = now()
   where id = v_user_id;

  return jsonb_build_object('success', true, 'had_profile', true);
end;
$$;
