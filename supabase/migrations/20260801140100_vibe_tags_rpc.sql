-- =============================================================================
-- Vibe Tags — RPC (v1.28)
--
-- 邊界跟 update_meeting_hint 同一套：JOINED 成員、status in (MATCHED,
-- ONGOING)，否則 ACTIVITY_NOT_ACTIVE。直接覆寫，不觸發通知（同 meeting_hint
-- ——個人化欄位，不是需要打斷對方的事件）。
-- =============================================================================

create or replace function update_vibe_tags(
  p_activity_id uuid,
  p_tags        text[]
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_tags     text[];
  v_tag      text;
  v_result   activity_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if p_tags is not null then
    if array_length(p_tags, 1) > 3 then
      raise exception using message = 'INVALID_INPUT', detail = 'TOO_MANY_TAGS';
    end if;
    foreach v_tag in array p_tags loop
      if char_length(v_tag) > 20 then
        raise exception using message = 'INVALID_INPUT', detail = 'TAG_TOO_LONG';
      end if;
    end loop;
  end if;
  -- 空陣列比照 meeting_hint 的空字串清空慣例，一律正規化成 null。
  v_tags := case when p_tags is null or array_length(p_tags, 1) is null then null else p_tags end;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  update activity_member
     set vibe_tags = v_tags
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  returning * into v_result;

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  return v_result;
end;
$$;
