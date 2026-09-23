-- =============================================================================
-- 修正：當 match_request 的邀請碼已被撤銷（revoked_at is not null）時，
-- 呼叫 get_or_create_invite_link 應產生全新的邀請碼並將 revoked_at 重設為 null，
-- 而非繼續回傳已被標記撤銷、join_request_by_token 無法加入的失效邀請碼。
--
-- 並發與原子性防護：
-- 使用 FOR UPDATE 鎖定目標 match_request 列，防止多台裝置或並發請求同時
-- 呼叫 get_or_create_invite_link 時產生競態條件（Race Condition）導致
-- 各自取得不同碼。首個交易取得鎖後產生新碼並寫入；後續排隊交易在鎖釋放後
-- 重新讀取已提交列（Read Committed），直接回傳已產生的有效碼，保證原子性與唯一性。
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

  -- 取得目標 match_request 列鎖，避免並發呼叫時重複產生互斥的邀請碼
  select invite_token, revoked_at into v_token, v_revoked_at
    from match_request
   where id = p_request_id and owner_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  -- 若從未產生過 token，或者既有 token 已被撤銷，則重新產生新 token 並重設 revoked_at
  if v_token is null or v_revoked_at is not null then
    v_token := encode(gen_random_bytes(12), 'hex');
    update match_request
       set invite_token = v_token,
           revoked_at = null
     where id = p_request_id and owner_id = v_user_id;
  end if;

  return v_token;
end;
$$;
