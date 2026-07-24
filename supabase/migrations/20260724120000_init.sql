-- =============================================================================
-- 校園活動配對 App — Supabase 初始 migration
-- 派生自 docs/SPEC.md (v1.1) + docs/ERD.md + docs/STATE_MACHINE.md
-- 若與 SPEC.md 衝突，以 SPEC.md 為準，先改 SPEC 再改本檔
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enums（值域定案於 ERD.md §2；State Machine 只定義轉移，不新增狀態）
-- -----------------------------------------------------------------------------

-- SPEC §2 (v1.2)：學校清單由 email domain mapping 硬編碼決定，新增學校本來就要改
-- migration（新網域規則），故用 enum、不開 School 表（ERD.md 備註 8）
create type school as enum ('NYCU', 'NTHU');

create type activity_type_status as enum ('PENDING', 'APPROVED', 'REJECTED');

create type request_status as enum ('DRAFT', 'REQUESTING', 'MATCHED', 'EXPIRED', 'CANCELLED');

create type request_member_role as enum ('OWNER', 'MEMBER');

create type request_member_status as enum ('JOINED', 'LEFT');

create type activity_status as enum ('MATCHED', 'ONGOING', 'COMPLETED', 'CANCELLED');

create type activity_member_status as enum ('JOINED', 'CANCELLED');

create type downgrade_status as enum ('PENDING', 'APPROVED', 'REJECTED', 'TIMEOUT');

create type downgrade_response as enum ('AGREE', 'DISAGREE', 'NO_RESPONSE');

create type completion_result as enum ('WENT_WELL', 'REPORTED_ABSENT', 'SELF_CANCELLED');

create type reliability_event_type as enum ('ATTENDED', 'EARLY_CANCEL', 'LATE_CANCEL', 'NO_SHOW');

-- SPEC §16 開放問題 5：事件清單可能擴充（enum 之後用 ALTER TYPE ... ADD VALUE 擴充）
create type notification_event_type as enum (
  'MATCH_SUCCESS', 'DOWNGRADE_REQUEST', 'DOWNGRADE_RESULT',
  'ACTIVITY_REMINDER', 'COMPLETE_CONFIRMATION'
);

-- -----------------------------------------------------------------------------
-- 2. Tables（13 張，順序依 FK 依賴）
-- -----------------------------------------------------------------------------

-- `user` 是 PostgreSQL 保留字，故命名 app_user；id 直接掛 Supabase Auth
create table app_user (
  id               uuid primary key references auth.users (id) on delete cascade,
  email            text not null unique
                   -- SPEC §2：完整比對雙校網域，僅 .edu.tw 後綴不夠
                   check (email ~* '^[^@]+@(nycu|nthu)\.edu\.tw$'),
  school           school not null,
  display_name     text not null,
  avatar_url       text not null,          -- SPEC §2：註冊硬性門檻
  gender           text,                   -- 僅展示，不進配對邏輯
  bio              text,                   -- 選填自我介紹，僅展示，不進配對邏輯（v1.3）
  contact_ig       text,
  contact_line     text,
  contact_discord  text,
  suspended_until  timestamptz,            -- 連續 3 次 No-show 停權 7 天
  created_at       timestamptz not null default now(),
  -- SPEC §2：至少 1 項外部聯絡方式，註冊時強制
  constraint at_least_one_contact check (
    contact_ig is not null or contact_line is not null or contact_discord is not null
  ),
  -- SPEC §2 (v1.2)：school 由信箱網域自動判定、不讓使用者自選——DB 層直接保證一致
  constraint school_matches_email check (
    (school = 'NYCU' and email ~* '@nycu\.edu\.tw$') or
    (school = 'NTHU' and email ~* '@nthu\.edu\.tw$')
  )
);

create table activity_type (
  id                        uuid primary key default gen_random_uuid(),
  name                      text not null unique,
  default_duration_minutes  int,           -- null 時 fallback = 60 (SYSTEM_DEFAULT_DURATION)
  status                    activity_type_status not null default 'PENDING',
  created_by                uuid references app_user (id),
  created_at                timestamptz not null default now()
);

create table location (
  id          uuid primary key default gen_random_uuid(),
  school      school not null,   -- SPEC §1 (v1.2)：地點清單依校分列
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (school, name)
);

-- 同校池隔離（SPEC §6/§7）：Request 建立時由 RPC 檢查 campus_location_id 屬於
-- owner 的 school（SCHOOL_LOCATION_MISMATCH，見 docs/API.md 3.1）；配上「地點必須
-- 完全相同才可 merge」，Matching Engine 不需額外判斷 school

create table match_request (
  id                       uuid primary key default gen_random_uuid(),
  owner_id                 uuid not null references app_user (id),
  activity_type_id         uuid not null references activity_type (id),
  campus_location_id       uuid not null references location (id),
  acceptable_location_ids  uuid[] not null default '{}',  -- v1 只填 1 個，預留多選
  earliest_start           timestamptz not null,
  latest_start             timestamptz not null,
  flexible_minutes         int not null default 0,        -- v1 固定 0，預留
  required_total           int not null check (required_total >= 2),
  allow_downgrade          boolean not null default false,
  status                   request_status not null default 'DRAFT',
  created_at               timestamptz not null default now(),
  constraint valid_time_window check (earliest_start <= latest_start),
  -- SPEC §0：所有 Request 必須在建立後 24 小時內開始
  constraint within_24h check (latest_start <= created_at + interval '24 hours')
);

-- SPEC §6：同一使用者同時只能有一個 REQUESTING 的 Request（DB 層直接擋）
create unique index one_requesting_per_owner
  on match_request (owner_id) where (status = 'REQUESTING');

-- Matching Engine 的 Queue 掃描主索引（依 activity_type 分流）
create index idx_request_queue
  on match_request (activity_type_id, campus_location_id, latest_start)
  where (status = 'REQUESTING');

-- 取代 member_ids[]（SPEC v1.1 變更 1）
create table request_member (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references match_request (id) on delete cascade,
  user_id     uuid not null references app_user (id),
  role        request_member_role not null default 'MEMBER',
  status      request_member_status not null default 'JOINED',
  created_at  timestamptz not null default now(),
  unique (request_id, user_id)
);

create index idx_request_member_user on request_member (user_id);

create table activity (
  id                     uuid primary key default gen_random_uuid(),
  activity_type_id       uuid not null references activity_type (id),
  campus_location_id     uuid not null references location (id),
  start_time             timestamptz not null,
  estimated_end_time     timestamptz not null,  -- = start_time + default_duration (fallback 60m)
  status                 activity_status not null default 'MATCHED',
  -- SPEC v1.1 變更 5：以本表 created_at 起算，不是來源 Request 的 created_at
  contact_visible_until  timestamptz not null default (now() + interval '24 hours'),
  created_at             timestamptz not null default now()
);

create index idx_activity_status_time on activity (status, start_time);

-- 取代 matched_request_ids[] / final_member_ids[]（SPEC v1.1 變更 2）
create table activity_member (
  activity_id        uuid not null references activity (id) on delete cascade,
  user_id            uuid not null references app_user (id),
  source_request_id  uuid not null references match_request (id),  -- 從哪個 Request 併進來
  status             activity_member_status not null default 'JOINED',
  primary key (activity_id, user_id)
);

create index idx_activity_member_user on activity_member (user_id);

create table downgrade_request (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references match_request (id) on delete cascade,
  target_size  int not null check (target_size >= 2),
  expire_at    timestamptz not null,  -- = created_at + 10 分鐘 CONSENT_WINDOW（SPEC §8）
  status       downgrade_status not null default 'PENDING',
  created_at   timestamptz not null default now()
);

create table downgrade_consent (
  downgrade_request_id  uuid not null references downgrade_request (id) on delete cascade,
  user_id               uuid not null references app_user (id),
  response              downgrade_response not null default 'NO_RESPONSE',
  responded_at          timestamptz,
  primary key (downgrade_request_id, user_id)
  -- 名單來源 = 該 request 的 request_member（SPEC §8），由建立 downgrade 的 RPC 展開寫入
);

create table completion_report (
  id               uuid primary key default gen_random_uuid(),
  activity_id      uuid not null references activity (id) on delete cascade,
  reporter_id      uuid not null references app_user (id),
  result           completion_result not null,
  absent_user_ids  uuid[] not null default '{}',  -- 一次性回報 payload，僅結算時讀取（ERD 備註 2）
  created_at       timestamptz not null default now(),
  unique (activity_id, reporter_id)  -- 每人每活動只能回報一次
);

-- SPEC v1.1 變更 4：Reliability 的資料來源，分數不存欄位、即時 query
create table user_reliability_event (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references app_user (id),
  activity_id  uuid not null references activity (id),
  event_type   reliability_event_type not null,
  created_at   timestamptz not null default now()
);

create index idx_reliability_user_time on user_reliability_event (user_id, created_at desc);

create table rematch_vote (
  activity_id   uuid not null references activity (id) on delete cascade,
  from_user_id  uuid not null references app_user (id),
  to_user_id    uuid not null references app_user (id),
  voted_at      timestamptz not null default now(),
  primary key (activity_id, from_user_id, to_user_id),
  constraint no_self_vote check (from_user_id <> to_user_id)
);

create table notification (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references app_user (id) on delete cascade,
  event_type  notification_event_type not null,
  payload     jsonb not null default '{}',
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index idx_notification_inbox on notification (user_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 3. Reliability helper functions（SPEC §12 / §12.1）
-- -----------------------------------------------------------------------------

-- 新人配對資格門檻（SPEC §12.1）：「尚未完成過任何活動」= 沒有任何 ATTENDED 事件
create function fn_is_new_user(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from user_reliability_event
    where user_id = p_user_id and event_type = 'ATTENDED'
  );
$$;

-- 展示層三級（SPEC §12）：近 30 天滾動資料；樣本 <5 顯示 NEW（冷啟動平滑）
-- ⚠ TRUSTED/NORMAL 的具體門檻值 SPEC 未定，此處為可調參數的第一版，調整不需改 schema
create function fn_reliability_tier(p_user_id uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_total    int;
  v_attended int;
  v_no_show  int;
begin
  select count(*),
         count(*) filter (where event_type = 'ATTENDED'),
         count(*) filter (where event_type = 'NO_SHOW')
    into v_total, v_attended, v_no_show
    from user_reliability_event
   where user_id = p_user_id
     and created_at >= now() - interval '30 days';

  if v_total < 5 then
    return 'NEW';
  elsif v_no_show = 0 and v_attended::numeric / v_total >= 0.8 then
    return 'TRUSTED';
  else
    return 'NORMAL';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Row Level Security（v1 baseline）
--
-- 原則：
--   * 一般讀取走 RLS；所有「狀態轉移」類寫入（submit/cancel/回報/降門檻回應）
--     一律走 security definer RPC 或 service-role 的 Edge Function（見 docs/API.md），
--     client 不直接 insert/update 狀態欄位
--   * 聯絡方式（contact_*）的互相可見規則（activity 成立 + contact_visible_until 未過
--     + 「再約」永久保留）不用 RLS 表達，統一走 RPC get_activity_contacts
-- -----------------------------------------------------------------------------

alter table app_user               enable row level security;
alter table activity_type          enable row level security;
alter table location               enable row level security;
alter table match_request          enable row level security;
alter table request_member         enable row level security;
alter table activity               enable row level security;
alter table activity_member        enable row level security;
alter table downgrade_request      enable row level security;
alter table downgrade_consent      enable row level security;
alter table completion_report      enable row level security;
alter table user_reliability_event enable row level security;
alter table rematch_vote           enable row level security;
alter table notification           enable row level security;

-- 自己的資料
create policy own_profile_select on app_user
  for select using (id = auth.uid());
create policy own_profile_update on app_user
  for update using (id = auth.uid());

-- 公開參照表：已核准的活動類型、啟用中的地點，登入即可讀
create policy approved_types_select on activity_type
  for select using (status = 'APPROVED' or created_by = auth.uid());
create policy active_locations_select on location
  for select using (is_active);

-- 自己相關的 Request（owner 或成員）
create policy my_requests_select on match_request
  for select using (
    owner_id = auth.uid()
    or exists (select 1 from request_member rm
               where rm.request_id = match_request.id and rm.user_id = auth.uid())
  );
create policy my_request_members_select on request_member
  for select using (
    user_id = auth.uid()
    or exists (select 1 from request_member me
               where me.request_id = request_member.request_id and me.user_id = auth.uid())
  );

-- 自己參加的 Activity 與同活動成員名單
create policy my_activities_select on activity
  for select using (
    exists (select 1 from activity_member am
            where am.activity_id = activity.id and am.user_id = auth.uid())
  );
create policy my_activity_members_select on activity_member
  for select using (
    exists (select 1 from activity_member me
            where me.activity_id = activity_member.activity_id and me.user_id = auth.uid())
  );

-- Downgrade：只有被詢問的成員能看到
create policy my_downgrades_select on downgrade_request
  for select using (
    exists (select 1 from downgrade_consent dc
            where dc.downgrade_request_id = downgrade_request.id and dc.user_id = auth.uid())
  );
create policy my_consents_select on downgrade_consent
  for select using (user_id = auth.uid());

-- 完成回報：只看得到自己交的（他人回報內容不公開，避免互相影響判定）
create policy own_reports_select on completion_report
  for select using (reporter_id = auth.uid());

-- Reliability 事件：只看得到自己的原始事件（他人只透過 fn_reliability_tier 看到等級）
create policy own_reliability_select on user_reliability_event
  for select using (user_id = auth.uid());

-- 再約投票：只看得到自己投出的（互按才生效的判定由 RPC 做，不暴露單向狀態）
create policy own_votes_select on rematch_vote
  for select using (from_user_id = auth.uid());

-- 通知：自己的收件匣
create policy own_notifications_select on notification
  for select using (user_id = auth.uid());
create policy own_notifications_update on notification
  for update using (user_id = auth.uid());
