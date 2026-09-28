-- =============================================================================
-- pgTAP Test: 47_anon_public_campus_demands.test.sql
--
-- 驗證已回退訪客探索功能，確認公開 RPC 已被移除且權限完整收回：
-- 1. get_public_campus_demands 函式已不存在
-- 2. anon_rate_limit_bucket 表已不存在
-- 3. anon 角色無法呼叫受保護的 get_campus_demands（42501 permission denied）
-- 4. anon 角色受 RLS 阻隔，無法讀取 match_request 與 request_member
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(5);

-- 1. 確認 get_public_campus_demands 函式已從 public schema 移除
select hasnt_function(
  'public',
  'get_public_campus_demands',
  'get_public_campus_demands 函式已被移除'
);

-- 2. 確認 anon_rate_limit_bucket 表已移除
select hasnt_table(
  'public',
  'anon_rate_limit_bucket',
  'anon_rate_limit_bucket 限流表已被移除'
);

-- 3. 匿名者無權呼叫 authenticated 限定的 get_campus_demands（Postgres 權限層拋出 42501）
set local role anon;

select throws_ok(
  $call$ select * from get_campus_demands('NYCU'::school, '光復') $call$,
  '42501',
  'permission denied for function get_campus_demands',
  'anon 訪客無法呼叫受保護的 get_campus_demands'
);

-- 4. 匿名者受 RLS 與 Grants 限制，無法讀取 match_request
select is_empty(
  $call$ select 1 from match_request $call$,
  'anon 角色無法讀取 match_request 原始活動資料'
);

-- 5. 匿名者受 RLS 與 Grants 限制，無法讀取 request_member
select is_empty(
  $call$ select 1 from request_member $call$,
  'anon 角色無法讀取 request_member 成員資料'
);

select * from finish();

rollback;
