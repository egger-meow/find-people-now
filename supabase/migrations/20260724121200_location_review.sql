-- =============================================================================
-- location 審核機制（比照 activity_type）+ propose_location RPC
-- 派生自使用者需求（v1.10）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. location：新增 status（復用 activity_type_status enum）與 created_by
-- -----------------------------------------------------------------------------
-- status 預設 'APPROVED'，刻意與 activity_type（預設 'PENDING'）不同：location
-- 的正常路徑是 admin 直接維護固定下拉清單（seed/Dashboard 直接 insert），
-- 'PENDING' 只在使用者走 propose_location 提案時才出現。created_by 允許 null，
-- 因為官方預先 seed 的地點沒有提案者。

alter table location
  add column status     activity_type_status not null default 'APPROVED',
  add column created_by uuid references app_user (id);

-- -----------------------------------------------------------------------------
-- 2. RLS：比照 activity_type 的 approved_types_select，讓提案者看得到自己那筆
--    PENDING，其他人看不到
-- -----------------------------------------------------------------------------

alter policy active_locations_select on location
  using (
    (is_active and status = 'APPROVED')
    or created_by = auth.uid()
  );

-- -----------------------------------------------------------------------------
-- 3. rpc: propose_location(name, school)
-- 提議新地點，流程比照 propose_activity_type：PENDING → admin 審核
-- （見 supabase/migrations/20260724121300_pending_review_view.sql）
-- -----------------------------------------------------------------------------
-- 不做關鍵字黑名單預檢：地點名稱要塞入色情/違法字眼的難度本來就比活動類型高，
-- 且 propose_activity_type 文件宣稱的黑名單預檢實際上從未實作過（見
-- app/lib/rpc/RPC_COVERAGE.md「Error codes documented in API.md but never
-- raised」）——與其複製一個不存在的機制，MVP 階段的真實把關就是
-- pending_review view 給 admin 人工看過再核准，這對地點提案已經足夠。

create or replace function propose_location(p_name text, p_school school)
returns location
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_trimmed text := trim(p_name);
  v_result  location;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and suspended_until > now()) then
    raise exception using message = 'USER_SUSPENDED';
  end if;

  if v_trimmed is null or v_trimmed = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'NAME_REQUIRED';
  end if;

  if exists (select 1 from location where school = p_school and name = v_trimmed) then
    raise exception using message = 'DUPLICATE_LOCATION_NAME';
  end if;

  insert into location (school, name, status, created_by, is_active)
  values (p_school, v_trimmed, 'PENDING', v_user_id, true)
  returning * into v_result;

  return v_result;
end;
$$;
