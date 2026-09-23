-- =============================================================================
-- 修正：當 match_request 的邀請碼已被撤銷（revoked_at is not null）時，
-- 呼叫 get_or_create_invite_link 應產生全新的邀請碼並將 revoked_at 重設為 null，
-- 而非繼續回傳已被標記撤銷、join_request_by_token 無法加入的失效邀請碼。
-- =============================================================================

create or replace function get_or_create_invite_link(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id    uuid := auth.uid();
  v_token      text;
  v_revoked_at timestamptz;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select invite_token, revoked_at into v_token, v_revoked_at
    from match_request
   where id = p_request_id and owner_id = v_user_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  -- 若從未產生過 token，或者既有 token 已被撤銷，則重新產生新 token 並重設 revoked_at
  if v_token is null or v_revoked_at is not null then
    v_token := encode(gen_random_bytes(12), 'hex');
    update match_request
       set invite_token = v_token,
           revoked_at = null
     where id = p_request_id;
  end if;

  return v_token;
end;
$$;
