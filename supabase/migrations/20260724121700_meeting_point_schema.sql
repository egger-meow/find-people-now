-- =============================================================================
-- Meeting Point / Meeting Hint — 正式 schema 落地 (v1.11.1)
--
-- 定案於兩輪前（campus-scope 討論當時），過去只留在文件（SPEC §9.1 的前瞻性原則），
-- 沒有對應的 table/RPC。這個 migration 才是真正的實作，跟「文件定案」區分開。
--
-- Meeting Point：append-only 記錄表，不做「只存最新一筆」的設計，也不刪舊資料。
-- 「目前集合點」= 依 created_at 取最新一筆；歷史展示 = 取最近 N 筆。跟
-- known_member_count／Reliability 分數「不額外存欄位，查詢時算」是同一個精神。
--
-- Meeting Hint：activity_member 新增一個 nullable text 欄位即可，不需要獨立表
-- （每人在每個 activity 只有一個 hint，沒有「歷史」需求）。
-- =============================================================================

create table activity_meeting_point_update (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references activity (id) on delete cascade,
  updated_by   uuid not null references app_user (id),
  description  text not null,
  -- 這張表唯一存在的目的就是「依 created_at 排序取最新」，用 now()（凍結在
  -- transaction 開始那一刻）在同一個 transaction 內多次寫入會拿到相同時間戳、
  -- 排序失去意義；用 clock_timestamp() 取真實時鐘時間，同表其他欄位仍照全庫
  -- 慣例用 now() 即可，只有這裡的排序語意特別要求要用它
  created_at   timestamptz not null default clock_timestamp()
);

-- 依 activity_id 取最新（或最近 N 筆）用這個索引；也是 2 分鐘冷卻檢查
-- （RPC 直接查「該使用者對該活動最近一次更新是否在冷卻窗口內」）的查詢路徑。
create index idx_activity_meeting_point_update_activity
  on activity_meeting_point_update (activity_id, created_at desc);

alter table activity_meeting_point_update enable row level security;

-- 公開透明給活動全體成員（跟 activity_location_option/vote 同一個精神：
-- 集合點協調是良性的群體資訊同步，不是 pending_confirmation 那種刻意不歸因的敏感情境）。
create policy my_activity_meeting_point_updates_select on activity_meeting_point_update
  for select using (
    exists (select 1 from activity_member am
            where am.activity_id = activity_meeting_point_update.activity_id and am.user_id = auth.uid())
  );

grant select on activity_meeting_point_update to authenticated;

alter table activity_member
  add column meeting_hint text check (char_length(meeting_hint) <= 30);

-- 冷卻時間走 app_config（既有的「運營可調參數」機制，跟 cooldown_minutes/
-- confirm_window_minutes/downgrade_consent_window_minutes 同一張表），不寫死在 RPC 裡。
insert into app_config (key, value, description) values
  ('meeting_point_update_cooldown_minutes', '2 minutes',
    'update_meeting_point 同一使用者對同一活動連續修改的冷卻時間（SPEC §9.2，v1.11.1）');

-- 必須在自己的 transaction 內先 commit，RPC migration 才能引用這個新 enum 值
-- （PostgreSQL 不允許在同一個 transaction 內新增並使用 enum label，跟
-- LOCATION_NOT_YET_PROPOSED 那次遇到的限制一樣）。
alter type notification_event_type add value if not exists 'MEETING_POINT_UPDATED';
