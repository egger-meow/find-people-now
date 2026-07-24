-- =============================================================================
-- v1.6 schema sync — 把 ERD.md（v1.6 定案）已寫定、但尚未落地到 init.sql 的變更補齊
-- 派生自 docs/ERD.md（v1.6）；若與 ERD.md 衝突，以 ERD.md 為準
--
-- 時間戳刻意早於 20260724120100_seed_defaults.sql：seed 檔會 insert
-- default_min_participants/default_max_participants/group_size_step，
-- 這幾個欄位必須先在這裡建立，seed 才跑得動。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app_user：補 department / degree_level（ERD.md app_user 區塊）
-- -----------------------------------------------------------------------------

create type degree_level as enum ('UNDERGRAD', 'MASTER', 'PHD');

alter table app_user
  add column department   text,
  add column degree_level degree_level;

-- 此表目前必為空（尚未上線），故可直接補 SET NOT NULL；
-- 若未來在已有資料的環境重跑此 migration，需要先 backfill 再補約束。
alter table app_user
  alter column degree_level set not null;

-- -----------------------------------------------------------------------------
-- 2. activity_type：補人數選項相關欄位（ERD.md activity_type 區塊，SPEC §6.2）
-- -----------------------------------------------------------------------------

alter table activity_type
  add column default_min_participants int,
  add column default_max_participants int,
  add column group_size_step         int;

-- -----------------------------------------------------------------------------
-- 3. match_request：required_total → min/max_participants + invite_token + revoked_at
--    （ERD.md match_request 區塊，設計備註 17/18）
-- -----------------------------------------------------------------------------

-- 改名沿用既有欄位與其 CHECK（>=2），不新開欄位、不丟既有資料
alter table match_request
  rename column required_total to min_participants;

alter table match_request
  add column max_participants int,
  add column invite_token     text unique,
  add column revoked_at       timestamptz;

alter table match_request
  add constraint max_participants_gte_min
    check (max_participants is null or max_participants >= min_participants);

-- -----------------------------------------------------------------------------
-- 4. request_status enum：補 PENDING_CONFIRMATION（ERD.md §2 enum 定案表，v1.4）
-- -----------------------------------------------------------------------------

alter type request_status add value if not exists 'PENDING_CONFIRMATION' after 'REQUESTING';

-- -----------------------------------------------------------------------------
-- 5. pending_confirmation（新表，ERD.md §2 enum 定案表 + 實體區塊，v1.4）
-- -----------------------------------------------------------------------------

create type pending_confirmation_status as enum ('PENDING', 'CONFIRMED', 'DECLINED', 'TIMEOUT');
create type pending_confirmation_response as enum ('CONFIRMED', 'DECLINED', 'NO_RESPONSE');

create table pending_confirmation (
  id                        uuid primary key default gen_random_uuid(),
  request_a_id              uuid not null references match_request (id),
  request_b_id              uuid not null references match_request (id),
  confirm_window_expire_at  timestamptz not null,  -- = created_at + 10 分鐘 CONFIRM_WINDOW（STATE_MACHINE R3b）
  user_a_response           pending_confirmation_response not null default 'NO_RESPONSE',
  user_b_response           pending_confirmation_response not null default 'NO_RESPONSE',
  status                    pending_confirmation_status not null default 'PENDING',
  created_at                timestamptz not null default now(),
  constraint distinct_requests check (request_a_id <> request_b_id)
);

-- Matching Engine 排程掃超時用（STATE_MACHINE PC2），比照 idx_request_queue 的寫法
create index idx_pending_confirmation_timeout
  on pending_confirmation (confirm_window_expire_at)
  where (status = 'PENDING');

-- 使用者查自己 Request 對應的候選配對
create index idx_pending_confirmation_request_a on pending_confirmation (request_a_id);
create index idx_pending_confirmation_request_b on pending_confirmation (request_b_id);

-- RLS：只開啟，不開 select policy。user_a_response/user_b_response 同存一行，
-- RLS 只能整行放行或拒絕，做不到「看得到自己那份、看不到對方那份」的列級隔離；
-- 硬開 policy 會讓任一方看到對方 response，違反 ERD 設計備註 16 / STATE_MACHINE
-- PC2「不透露對方回應內容」的不歸因設計。
-- ⚠ API.md 提醒：Matching Engine (SECURITY DEFINER / Service Role) 可自然繞過 RLS
-- 進行全表讀寫；前端若需查詢雙方狀態，必須在 API.md 階段定義專用 SECURITY DEFINER RPC
-- （如 get_pending_confirmation_status），僅回傳 status 而不暴露個人 response 明細。
alter table pending_confirmation enable row level security;

-- -----------------------------------------------------------------------------
-- 6. match_history_avoidance（新表，ERD.md §2 enum 定案表 + 實體區塊 + 設計備註 15，v1.4）
-- -----------------------------------------------------------------------------

create table match_history_avoidance (
  id                              uuid primary key default gen_random_uuid(),
  user_a_id                       uuid not null references app_user (id),
  user_b_id                       uuid not null references app_user (id),
  source_pending_confirmation_id  uuid not null references pending_confirmation (id),
  failed_at                       timestamptz not null default now(),
  expire_at                       timestamptz not null default (now() + interval '7 days'),
  -- 正規化：pair 中較小的 UUID 存 user_a_id，較大的存 user_b_id，DB 層直接保證，
  -- 不靠應用層自律（設計備註 15：查降權只需查一次，不用 OR 兩種順序）
  constraint normalized_pair check (user_a_id < user_b_id)
);

-- Matching Engine 撮合時查降權用（設計備註 15 正規化後的單一查詢路徑）
create index idx_match_history_avoidance_pair on match_history_avoidance (user_a_id, user_b_id);

-- RLS：只開啟、不開任何 select policy。這張表記錄「誰跟誰配對失敗過」，比
-- 「對方回報內容不公開」更敏感，不該讓任何使用者直接查到；
-- ⚠ API.md 提醒：此表僅由 Matching Engine 的 SECURITY DEFINER 函數於撮合時繞過 RLS 存取。
alter table match_history_avoidance enable row level security;
