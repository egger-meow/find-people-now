-- =============================================================================
-- 修正 bug：request_member 的 SELECT RLS policy 自我參照造成無限遞迴
-- =============================================================================
-- 發現經過：這輪（前端配對頁+等待室）第一次讓 `authenticated` 角色直接對
-- match_request/request_member 做 Realtime 訂閱（`.stream()` 底層就是
-- `authenticated` 角色的 SELECT，見 UI_PLAN.md §3）。跑真實整合測試時炸出
-- `ERROR: infinite recursion detected in policy for relation "request_member"`
-- （code 42P17）。
--
-- 跟 20260724121900_fix_activity_member_rls_recursion.sql 修的是同一種 bug、
-- 同一個根因、同一個修法，只是換了一張表：`my_request_members_select`
-- （20260724120000_init.sql:304-309）在自己的 USING 子句裡直接
-- `exists (select 1 from request_member me where ...)`，PostgreSQL 對「同一張
-- 表在自己的 RLS policy 裡查詢自己」一律偵測為遞迴並直接報錯，不是效能問題。
--
-- 過去沒被抓到的原因跟 activity_member 那次一模一樣：所有既有 pgTAP 測試都用
-- postgres superuser 或 `set_config` 模擬 auth.uid() 直接查詢（略過 RLS），
-- 前端也只透過 SECURITY DEFINER RPC 存取 match_request/request_member，從未
--真的以 authenticated 角色 SELECT 這兩張表——直到這輪 Realtime 訂閱第一次
-- 真的這樣做。
--
-- 修法：沿用既有慣例，用 SECURITY DEFINER helper function 包住判斷——function
-- 以擁有者身份執行，內部查詢不會再觸發呼叫者的 RLS policy，因此不會遞迴。
-- `match_request` 的 `my_requests_select` 不用動：它查詢 request_member 只是
-- 觸發對方的 policy 評估，一旦 request_member 自己的 policy 不再遞迴，
-- match_request 這邊自然也不會了（跟 activity/activity_member 那次的修法
-- 範圍完全對應：只修被自我參照的那張表，不用動引用它的其他表）。
-- =============================================================================

create or replace function fn_is_request_member(p_request_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from request_member
     where request_id = p_request_id and user_id = p_user_id
  );
$$;

drop policy my_request_members_select on request_member;

create policy my_request_members_select on request_member
  for select using (
    user_id = auth.uid()
    or fn_is_request_member(request_id, auth.uid())
  );
