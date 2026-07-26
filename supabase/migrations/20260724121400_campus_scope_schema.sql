-- =============================================================================
-- Matching Engine 空間維度重構：schema 變更（v1.11）
-- 派生自使用者需求：campus_location_id 精確地點匹配 → (school, campus) 範圍匹配
-- 若與 SPEC.md / ERD.md 衝突，以 SPEC.md / ERD.md 為準（本檔應與 v1.11 變更同步）
--
-- 本檔只動 schema（欄位、表、RLS、grants、app_config、enum）；RPC 邏輯改寫見
-- 20260724121500_campus_scope_rpc.sql（刻意拆成獨立 migration，讓 ALTER TYPE
-- ... ADD VALUE 先在自己的 transaction 內 commit，避免同一 transaction 內
-- 定義／使用新 enum label 的順序風險）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. location：新增 campus（陽明交大橫跨新竹/台北/台南三市，school 本身不足以
--    代表「距離夠近」，需要更細一級的 campus 欄位；用純文字、不開 enum、不另開
--    Campus 表——campus 清單會隨你之後補的地點清單擴充，屬於資料而非程式碼的
--    範圍，比照 location.name/activity_type.name 既有的純文字慣例）
-- -----------------------------------------------------------------------------
-- 目前 migration 階段 location 表尚無任何 seed 資料（seed_defaults.sql 明確註記
-- 地點清單另外補 insert，且既有唯二兩筆地點只存在於 pgTAP 測試 fixture 的交易內／
-- README 的手動 docker exec insert，不是 migration 產生的持久資料），故可直接加
-- NOT NULL 欄位、不需要回填；pgTAP 測試 fixture 與 README 手動 insert 語句需要
-- 在後續 commit 補上 campus 值。若未來在已有資料的環境重跑此 migration，需要先
-- backfill 再補約束（比照 20260724120050_v1_6_schema_sync.sql 對 degree_level
-- 的既有註記）。

alter table location
  add column campus text not null;

-- -----------------------------------------------------------------------------
-- 2. match_request：campus_location_id（精確地點 FK）→ school + campus
--    （Matching Scope 改成範圍匹配，不再要求精確同一地點）
-- -----------------------------------------------------------------------------
-- 同時移除 acceptable_location_ids[]：這個欄位原本的定位是「v1 只填 1 個精確
-- 地點，欄位預留未來多選」，但新模型下 Request 建立時根本不指定精確地點，
-- 語意已經跟新模型直接衝突——是「語意不存在」而不是「deprecated 保留」，故直接
-- 砍除，不留欄位造成誤導（SPEC.md/ERD.md v1.11 變更紀錄明確記載此點）。

alter table match_request
  drop column campus_location_id,
  drop column acceptable_location_ids,
  add column school school not null,
  add column campus text   not null;

drop index if exists idx_request_queue;
create index idx_request_queue
  on match_request (activity_type_id, school, campus, latest_start)
  where (status = 'REQUESTING');

-- -----------------------------------------------------------------------------
-- 3. activity：campus_location_id（精確地點 FK，撮合當下直接複製自 Request）
--    → school + campus（Matching Scope 快照，撮合當下就有）+ activity_location_id
--    （Activity Location，配對成立後才透過投票決定，nullable）
-- -----------------------------------------------------------------------------

alter table activity
  drop column campus_location_id,
  add column school               school not null,
  add column campus               text   not null,
  add column activity_location_id uuid references location (id);

-- -----------------------------------------------------------------------------
-- 4. Activity Location 投票機制：借用既有基礎設施（activity_member 判定資格、
--    location 表本身當候選來源），只新增 2 張表，不做成獨立子系統
-- -----------------------------------------------------------------------------

create table activity_location_option (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references activity (id) on delete cascade,
  location_id  uuid not null references location (id),
  proposed_by  uuid not null references app_user (id),
  created_at   timestamptz not null default now(),
  unique (activity_id, location_id)
);

create index idx_activity_location_option_activity on activity_location_option (activity_id);

-- 得票數不落地存欄位，查詢即時算出（比照 known_member_count/Reliability 分數
-- 不額外儲存同一精神）；一人一票，改票 = update 這筆（unique(activity_id, user_id)）
create table activity_location_vote (
  activity_id  uuid not null references activity (id) on delete cascade,
  user_id      uuid not null references app_user (id),
  location_id  uuid not null references location (id),
  voted_at     timestamptz not null default now(),
  primary key (activity_id, user_id)
);

create index idx_activity_location_vote_location on activity_location_vote (activity_id, location_id);

-- RLS：跟 pending_confirmation 的刻意不透明相反——地點偏好分歧是真實分歧，
-- 公開透明才符合「大家一起選」的精神，比照 my_activity_members_select 的既有
-- 「同活動成員互相看得到」模式
alter table activity_location_option enable row level security;
alter table activity_location_vote   enable row level security;

create policy my_activity_location_options_select on activity_location_option
  for select using (
    exists (select 1 from activity_member am
            where am.activity_id = activity_location_option.activity_id and am.user_id = auth.uid())
  );

create policy my_activity_location_votes_select on activity_location_vote
  for select using (
    exists (select 1 from activity_member am
            where am.activity_id = activity_location_vote.activity_id and am.user_id = auth.uid())
  );

-- 這兩張表是本檔新增，20260724120800_grants.sql 寫成當時它們還不存在；比照該檔
-- 「有 select policy 才 grant select」的既有原則，直接在建表的同一個 migration
-- 就把 grant 補齊，不回頭改舊檔。寫入一律走下一份 migration 的 SECURITY DEFINER
-- RPC（propose_activity_location/vote_activity_location），不開 insert/update grant。
grant select on activity_location_option to authenticated;
grant select on activity_location_vote   to authenticated;

-- -----------------------------------------------------------------------------
-- 5. app_config：新增零候選地點提醒的提前量（比照 §13.1 既有「時間參數抽成
--    可調值、不寫死」慣例）
-- -----------------------------------------------------------------------------

insert into app_config (key, value, description) values
  ('location_reminder_lead_minutes', '30 minutes',
    '零候選地點提醒（fn_remind_missing_location_candidates）的提前量：activity.start_time 前多久仍無任何 activity_location_option 就發送 LOCATION_NOT_YET_PROPOSED 通知（SPEC v1.11）');

-- -----------------------------------------------------------------------------
-- 6. notification_event_type：新增 LOCATION_NOT_YET_PROPOSED
--    （SPEC §16 開放問題 5 本來就預告這張 enum 會擴充；獨立成本檔最後一步，
--    確保下一份 migration 使用這個 label 時已經是「先前 transaction 已 commit」
--    的安全狀態）
-- -----------------------------------------------------------------------------

alter type notification_event_type add value if not exists 'LOCATION_NOT_YET_PROPOSED';
