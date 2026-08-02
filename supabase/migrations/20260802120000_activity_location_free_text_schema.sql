-- =============================================================================
-- Activity Location 投票候選開放自由輸入（v1.30）：schema 變更
-- 派生自使用者需求：候選地點過去僅限 location 表既有 status='APPROVED' 的地點
-- （SPEC v1.10/v1.11「不開放自由輸入，延續固定清單原則」），但活動類型已擴充到
-- 桌遊、麻將、校外咖啡廳等——這類地點通常只用這一次，硬要求先送 admin 審核、
-- 永久寫進全域 location 清單既不合理也造成清單污染。這裡新增「僅該活動可見的
-- 自訂候選」，跳過審核，且刻意不落地到 location 表（不是新增一種 location.status，
-- 見本檔規劃取捨）。propose_location（送審加入全域清單）機制維持不變，仍是想
-- 讓一個地點被其他活動重複使用時的正規路徑。
--
-- 本檔只動 schema；RPC 邏輯改寫見 20260802120100_activity_location_free_text_rpc.sql
-- （沿用 20260724121400/121500 拆檔慣例，schema 與 RPC 分開兩份 migration）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. activity_location_option：新增 custom_name，location_id 改 nullable，
--    CHECK 兩者恰好其一非空（XOR）——不整合成「custom location 也寫一筆到
--    location 表、只是標記特殊 status」，那樣資料本質上還是「永久增加到地點
--    資料庫」，只是從清單畫面過濾掉，跟使用者「不會永久增到預設地點資料庫」
--    的訴求不符，且會隨活動數量線性累積孤兒 location 列、需要額外清理機制。
-- -----------------------------------------------------------------------------

alter table activity_location_option
  add column custom_name text,
  alter column location_id drop not null,
  add constraint activity_location_option_source_xor
    check ((location_id is not null) <> (custom_name is not null)),
  add constraint activity_location_option_custom_name_length
    check (custom_name is null or char_length(custom_name) between 1 and 40);

-- 既有 unique(activity_id, location_id) 對 custom_name 候選沒有防重複效果
-- （location_id 為 null 時，NULL 之間天生不視為衝突）；custom_name 另外用
-- 大小寫不敏感的 partial unique index 防同一活動重複新增同名自訂候選——沿用
-- 既有「提案已存在的候選 = 退化成投票，不算錯誤」精神，讓 RPC 層可以用
-- on conflict 偵測到重複。
create unique index activity_location_option_custom_name_key
  on activity_location_option (activity_id, lower(custom_name))
  where custom_name is not null;

-- -----------------------------------------------------------------------------
-- 2. activity_location_vote：location_id → option_id（改投給候選本身，不再
--    投給地點）——custom_name 候選沒有 location_id 可投，且改成 option_id 後
--    location_id/custom_name 两種候選的計票、鎖定邏輯完全統一，不必為 custom
--    候選另外分岔一套查詢。沿用同一張表、同一組 RLS/grants（RLS 只依 activity_id
--    判斷成員資格，跟投票對象的欄位無關，不需要動）。
-- -----------------------------------------------------------------------------

drop index if exists idx_activity_location_vote_location;

-- 環境無正式資料（同上，本 repo 一貫用 db reset 重放 migration），直接
-- drop 舊欄位、加新欄位，不做遷移期回填。
alter table activity_location_vote
  drop column location_id,
  add column option_id uuid not null references activity_location_option (id) on delete cascade;

create index idx_activity_location_vote_option on activity_location_vote (activity_id, option_id);

-- -----------------------------------------------------------------------------
-- 3. activity.activity_location_id：FK 改指向 activity_location_option(id)，
--    不再直接指向 location(id)——鎖定結果現在可能是一個 custom_name 候選，
--    没有對應的 location 列可指。ERD 設計備註 31/32 對「候選/得票」的既有設計
--    精神不變，只是鎖定結果從「地點本身」改成「候選記錄」，跟
--    activity_location_option 本來就同時涵蓋 location_id/custom_name 兩種來源
--    一致。目前環境無正式使用者資料（本 repo 一貫用 supabase db reset 重放
--    migration，不含遷移期回填），直接 drop/re-add constraint。
-- -----------------------------------------------------------------------------

alter table activity
  drop constraint activity_activity_location_id_fkey,
  add constraint activity_activity_location_id_fkey
    foreign key (activity_location_id) references activity_location_option (id);
