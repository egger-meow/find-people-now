-- v1.33: get_activity_member_profiles 新增 bio 欄位 —— 個人檔案卡
--
-- 起因：使用者要求配對成立後的成員名單可以點開頭像看更完整的個人檔案卡
-- （照片、科系、自我介紹）。bio 跟 department 同屬「一般個人資料、不比照
-- contacts 加時效/再約閘門」（見 docs/API.md §6.1.1），本來就該放在
-- get_activity_member_profiles 這支 RPC，而不是 get_activity_contacts——
-- 後者的既有範圍刻意只管身份＋有時效的聯絡方式（見
-- 20260724125700_activity_member_profiles.sql 檔頭註解「刻意不重複
-- display_name/avatar_url/contacts」），加進 get_activity_contacts 會破壞
-- 這條既有的職責分工。
--
-- 函式簽名/存取檢查完全不變，照抄
-- 20260724125700_activity_member_profiles.sql 的定義，只在
-- jsonb_build_object 裡多加一個 key。
create or replace function get_activity_member_profiles(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_members jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  if not exists (select 1 from activity where id = p_activity_id) then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'school', u.school,
      'department', u.department,
      'degree_level', u.degree_level,
      'bio', u.bio,
      'reliability_tier', fn_reliability_tier(u.id)
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
 where am.activity_id = p_activity_id;

  return coalesce(v_members, '[]'::jsonb);
end;
$$;
