-- =============================================================================
-- 使用者主動封鎖 — schema（v1.17）
-- 派生自使用者需求：單方面生效、不通知對方、只影響未來配對、不影響進行中活動。
--
-- 刻意不與既有 match_history_avoidance 共用同一張表：那張表是系統自動寫入、
-- 7 天到期、不區分「誰對誰」的方向（正規化 pair，見 20260724120050 設計備註 15）；
-- 這張表是使用者主動、永久（不到期）、有方向性（誰封鎖誰有語意差異）、可自行
-- 解除（unblock_user）。語意完全不同，獨立建表避免牽動既有核心撮合邏輯的風險。
-- =============================================================================

create table user_block (
  id          uuid primary key default gen_random_uuid(),
  blocker_id  uuid not null references app_user (id),
  blocked_id  uuid not null references app_user (id),
  reason      text,
  created_at  timestamptz not null default now(),
  unique (blocker_id, blocked_id),
  constraint no_self_block check (blocker_id <> blocked_id)
);

-- Matching Engine 撮合時查封鎖用（見 20260724124300_matching_engine_user_block_check.sql）
create index idx_user_block_blocker on user_block (blocker_id);
create index idx_user_block_blocked on user_block (blocked_id);

-- RLS：只有封鎖發起人自己看得到這筆記錄——被封鎖方永遠不該、也不會知道自己被封鎖，
-- 這是功能設計的核心前提，不是漏做 select-all policy。
alter table user_block enable row level security;

create policy own_blocks_select on user_block
  for select using (blocker_id = auth.uid());

-- 封鎖清單查詢直接用 PostgREST（GET user_block?blocker_id=eq.<self>），不需額外 RPC；
-- 寫入/刪除一律走 block_user/unblock_user（SECURITY DEFINER RPC），故不 grant insert/delete。
grant select on user_block to authenticated;
