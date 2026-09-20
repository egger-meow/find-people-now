-- =============================================================================
-- 修復 RLS 輔助函數執行權限
--
-- 根因：
-- 20260810095310_restrict_security_definer_execution.sql 遍歷所有 public 綱要下的
-- security definer 函數並執行了 revoke execute ... from public, anon, authenticated。
-- 這無意間連同 RLS policy 所依賴的內部查詢輔助函數 fn_is_request_member 與
-- fn_is_activity_member 的 execute 權限也一併撤銷。
--
-- 當 authenticated 使用者透過 PostgREST 查詢 match_request、request_member、
-- activity 或 activity_member 表時，Postgres 在評估 RLS policy 時因無權執行此二函數，
-- 拋出 "42501: permission denied for function fn_is_request_member/fn_is_activity_member"，
-- 導致前端「我的活動」清單無法載入。
--
-- 本遷移重新補齊 authenticated 與 anon 對這兩個 helper 的 execute 權限。
-- =============================================================================

grant execute on function fn_is_request_member(uuid, uuid) to authenticated, anon;
grant execute on function fn_is_activity_member(uuid, uuid) to authenticated, anon;
