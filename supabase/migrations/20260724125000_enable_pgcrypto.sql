-- =============================================================================
-- 修正 bug：get_or_create_invite_link / delete_account 的 token 產生從未真的能跑
-- =============================================================================
-- 發現經過：這輪前端整合測試第一次真的呼叫 `get_or_create_invite_link`
-- （UI_PLAN.md §3「邀請朋友」）打到真實本地實例，噴
-- `function gen_random_bytes(integer) does not exist`。
--
-- 根因：`gen_random_bytes` 是 pgcrypto 提供的函式（不像 gen_random_uuid()
-- 是 Postgres 13+ 核心內建），但翻遍所有既有 migrations 從未
-- `create extension pgcrypto`。20260724120300_rpc_match_request.sql:296 與
-- 20260724122600_delete_account_guard.sql:501 都呼叫了 gen_random_bytes——
-- 兩處都是從未被任何 pgTAP 測試真正呼叫過的路徑（沒有任何測試檔案呼叫
-- get_or_create_invite_link 這個 RPC 名字），所以這個 bug 存在了好幾輪都沒被
-- 抓到，直到這輪前端第一次真的跑過這條路徑。
-- =============================================================================

create extension if not exists pgcrypto;
