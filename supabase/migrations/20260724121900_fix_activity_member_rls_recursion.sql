-- =============================================================================
-- 修正 bug：activity_member 的 SELECT RLS policy 自我參照造成無限遞迴
--
-- 發現經過：撰寫 07_meeting_point_and_hint.test.sql 的 RLS 測試時（第一次有
-- pgTAP 測試真的以 `authenticated` 角色查詢會 join 到 activity_member 的表），
-- 觸發 `ERROR: infinite recursion detected in policy for relation
-- "activity_member"`。獨立驗證後確認：這個 bug 早就存在（20260724120000_init.sql
-- 原始定義），且範圍遠大於這次的 Meeting Point 功能本身——任何 authenticated
-- 角色對 activity 或 activity_member 的查詢都會炸掉，因為 activity 的 SELECT
-- policy 也會 join 到 activity_member，間接觸發同一個遞迴。過去沒被抓到是因為
-- 所有既有 pgTAP 測試都只用 postgres superuser 連線做設置/斷言查詢（略過
-- RLS），前端也只透過 SECURITY DEFINER RPC 存取，從未直接以 authenticated
-- 角色 SELECT 這兩張表。
--
-- 根因：原 policy 直接在自己的 USING 子句裡 `exists (select 1 from
-- activity_member me where ...)`，PostgreSQL 對「同一張表在自己的 RLS policy
-- 裡查詢自己」會偵測為遞迴並直接拒絕，不是效能問題，是直接報錯。
--
-- 修法：比照全庫既有慣例（fn_get_config_interval 等），用一個 SECURITY
-- DEFINER 的 helper function 包住這個判斷——function 以擁有者身份執行，
-- 內部查詢不會再觸發呼叫者的 RLS policy，因此不會遞迴。
-- =============================================================================

create or replace function fn_is_activity_member(p_activity_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = p_user_id
  );
$$;

drop policy my_activity_members_select on activity_member;

create policy my_activity_members_select on activity_member
  for select using (fn_is_activity_member(activity_id, auth.uid()));
