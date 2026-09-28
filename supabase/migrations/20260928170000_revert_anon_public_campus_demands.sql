-- =============================================================================
-- Migration: 20260928170000_revert_anon_public_campus_demands.sql
-- 
-- 回退訪客公開活動探索功能：
-- 1. 撤銷並刪除 get_public_campus_demands RPC
-- 2. 刪除 anon_rate_limit_bucket 表
-- 3. 恢復所有活動需求瀏覽僅限通過學校信箱驗證之 authenticated 用戶
-- =============================================================================

-- 1. 撤銷權限並移除函式
revoke execute on function public.get_public_campus_demands(school, text) from public, anon, authenticated;
drop function if exists public.get_public_campus_demands(school, text);

-- 2. 移除匿名限流表
drop table if exists public.anon_rate_limit_bucket;
