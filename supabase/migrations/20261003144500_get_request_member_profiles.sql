-- =============================================================================
-- Migration: get_request_member_profiles RPC (API §3.9)
-- =============================================================================
-- 目的：允許 MatchRequest（含 DRAFT 與 REQUESTING）的 JOINED 成員查看同房間夥伴
-- 的公開個人資訊（user_id、display_name、avatar_url、role、status、created_at）。
--
-- 理由：原本系統為落實「盲配不挑人」，app_user 的 own_profile_select RLS 僅放行查自己，
-- 且後端只有在成團（Activity）後才提供 get_activity_member_profiles / get_activity_contacts。
-- 導致使用者透過邀請連結找好友入房後，等待室與邀請頁無法得知誰已進房，只能顯示完全匿名的
-- 佔位圖標（藍星/綠人），嚴重傷害使用者確認「好友是否到齊」的體驗。
--
-- 安全邊界：
-- 1. 僅限該 Request 的 JOINED 成員呼叫；非成員呼叫拋出 NOT_REQUEST_MEMBER。
-- 2. 嚴格限定在「同一 Request 房間內的成員」，絕不洩漏外部其他 Request 或陌生候選對象。
-- =============================================================================

create or replace function get_request_member_profiles(p_request_id uuid)
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

  if not exists (select 1 from match_request where id = p_request_id) then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  -- 呼叫者必須為該 Request 的 JOINED 成員
  if not exists (
    select 1 from request_member rm
     where rm.request_id = p_request_id
       and rm.user_id = v_user_id
       and rm.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_REQUEST_MEMBER';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'display_name', u.display_name,
      'avatar_url', u.avatar_url,
      'role', rm.role,
      'status', rm.status,
      'created_at', rm.created_at
    ) order by (case when rm.role = 'OWNER' then 0 else 1 end), rm.created_at asc
  ) into v_members
  from request_member rm
  join app_user u on u.id = rm.user_id
  where rm.request_id = p_request_id
    and rm.status = 'JOINED';

  return coalesce(v_members, '[]'::jsonb);
end;
$$;

grant execute on function get_request_member_profiles(uuid) to authenticated;
