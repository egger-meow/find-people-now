-- =============================================================================
-- Phase 2 RPCs — ActivityType & Location
-- 派生自 docs/SPEC.md §5 及 docs/API.md §2
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: search_activity_type
-- 活動類型模糊搜尋 / autocomplete
-- -----------------------------------------------------------------------------

create or replace function search_activity_type(p_query text)
returns setof activity_type
language sql
stable
security definer
set search_path = public
as $$
  select *
    from activity_type
   where status = 'APPROVED'
     and (p_query is null or trim(p_query) = '' or name ilike '%' || trim(p_query) || '%')
   order by name;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: propose_activity_type
-- 提議新活動類型（進行預檢與黑名單過濾）
-- -----------------------------------------------------------------------------

create or replace function propose_activity_type(p_name text)
returns activity_type
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_trimmed text := trim(p_name);
  v_result  activity_type;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using errcode = 'USER_SUSPENDED', message = 'USER_SUSPENDED';
  end if;

  if v_trimmed is null or v_trimmed = '' then
    raise exception using errcode = 'INVALID_INPUT', message = 'NAME_REQUIRED';
  end if;

  -- 重複名稱檢查
  if exists (select 1 from activity_type where name = v_trimmed) then
    raise exception using errcode = 'DUPLICATE_TYPE_NAME', message = 'DUPLICATE_TYPE_NAME';
  end if;

  insert into activity_type (name, status, created_by)
  values (v_trimmed, 'PENDING', v_user_id)
  returning * into v_result;

  return v_result;
end;
$$;
