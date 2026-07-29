-- v1.23: get_activity_member_profiles(activity_id) — UI_PLAN §4.1 Tab 2「成員」
-- 名單需要顯示 school/department/degree_level/可信度等級，但
-- get_activity_contacts（20260724120500_rpc_activity_and_contacts.sql）只回傳
-- display_name/avatar_url/role/contacts，app_user 的 own_profile_select RLS
-- 又只放行查自己，前端沒有任何路徑能拿到其他成員的這些欄位。見
-- docs/SPEC.md v1.23 變更紀錄、docs/API.md §6.1.1。
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

  -- 判準與 get_activity_contacts 完全相同：呼叫者須為該活動 JOINED 成員。
  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 刻意不過濾 am.status（同 get_activity_contacts），回傳全體成員（含
  -- CANCELLED），由呼叫端自行判斷要不要顯示——跟 6.1 GET activity_member 直讀
  -- 拿到的 status 集合一致，不製造兩份不同步的成員清單。
  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'school', u.school,
      'department', u.department,
      'degree_level', u.degree_level,
      'reliability_tier', fn_reliability_tier(u.id)
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
 where am.activity_id = p_activity_id;

  return coalesce(v_members, '[]'::jsonb);
end;
$$;
