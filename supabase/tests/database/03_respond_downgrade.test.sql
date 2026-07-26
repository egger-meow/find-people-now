-- =============================================================================
-- pgTAP Test — respond_downgrade (docs/API.md §5.1)
-- 之前完全沒有實作，這份測試涵蓋 STATE_MACHINE.md「Downgrade 子流程」列出的
-- 四種結局：非受詢問方 (FORBIDDEN)、部分同意 (仍 PENDING)、全員同意 (APPROVED)、
-- 任一人不同意 (立即 REJECTED)，以及 CONSENT_WINDOW_CLOSED、重複回應
-- (ALREADY_RESPONDED)、ERD 設計備註 21 的 target_size 應用層防呆 (INVALID_INPUT)。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(7);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_a_id  uuid,  -- req1 member, 用來測 FORBIDDEN 的呼叫者是 user_c（非成員）
  user_b_id  uuid,  -- req1 member
  user_c_id  uuid,  -- 完全不在任何 downgrade_consent 名單裡
  user_d_id  uuid,  -- req2 member (disagree 分支)
  user_e_id  uuid,  -- req2 member (disagree 分支)
  user_f_id  uuid,  -- dg3 (過期窗口)
  user_g_id  uuid,  -- dg4 (target_size 防呆)
  act_type_id uuid,
  loc_id      uuid,
  req1_id     uuid,
  req2_id     uuid,
  req3_id     uuid,
  req4_id     uuid,
  dg1_id      uuid,
  dg2_id      uuid,
  dg3_id      uuid,
  dg4_id      uuid
);
insert into fixtures default values;

do $setup$
declare
  v_user_a uuid := gen_random_uuid();
  v_user_b uuid := gen_random_uuid();
  v_user_c uuid := gen_random_uuid();
  v_user_d uuid := gen_random_uuid();
  v_user_e uuid := gen_random_uuid();
  v_user_f uuid := gen_random_uuid();
  v_user_g uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_loc_id      uuid;
  v_req1 match_request;
  v_req2 match_request;
  v_req3 match_request;
  v_req4 match_request;
  v_dg1  uuid;
  v_dg2  uuid;
  v_dg3  uuid;
  v_dg4  uuid;
begin
  insert into auth.users (id, email) values
    (v_user_a, 'dg_a@nycu.edu.tw'), (v_user_b, 'dg_b@nycu.edu.tw'), (v_user_c, 'dg_c@nycu.edu.tw'),
    (v_user_d, 'dg_d@nycu.edu.tw'), (v_user_e, 'dg_e@nycu.edu.tw'), (v_user_f, 'dg_f@nycu.edu.tw'),
    (v_user_g, 'dg_g@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_user_a, 'dg_a@nycu.edu.tw', 'NYCU', 'Dg A', 'https://avatar.dg_a', 'MASTER', 'dg_a_line'),
    (v_user_b, 'dg_b@nycu.edu.tw', 'NYCU', 'Dg B', 'https://avatar.dg_b', 'MASTER', 'dg_b_line'),
    (v_user_c, 'dg_c@nycu.edu.tw', 'NYCU', 'Dg C', 'https://avatar.dg_c', 'MASTER', 'dg_c_line'),
    (v_user_d, 'dg_d@nycu.edu.tw', 'NYCU', 'Dg D', 'https://avatar.dg_d', 'MASTER', 'dg_d_line'),
    (v_user_e, 'dg_e@nycu.edu.tw', 'NYCU', 'Dg E', 'https://avatar.dg_e', 'MASTER', 'dg_e_line'),
    (v_user_f, 'dg_f@nycu.edu.tw', 'NYCU', 'Dg F', 'https://avatar.dg_f', 'MASTER', 'dg_f_line'),
    (v_user_g, 'dg_g@nycu.edu.tw', 'NYCU', 'Dg G', 'https://avatar.dg_g', 'MASTER', 'dg_g_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;
  insert into location (school, name, is_active) values ('NYCU', '學生活動中心', true)
    on conflict (school, name) do update set is_active = true;
  select id into v_loc_id from location where school = 'NYCU' and name = '學生活動中心';

  -- req1: min_participants=4，僅 user_a/user_b 兩人（模擬人數不足、發起 downgrade）
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user_a, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 4, 4, 'REQUESTING')
  returning * into v_req1;
  insert into request_member (request_id, user_id, role, status) values
    (v_req1.id, v_user_a, 'OWNER', 'JOINED'), (v_req1.id, v_user_b, 'MEMBER', 'JOINED');

  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req1.id, 2, now() + interval '10 minutes', 'PENDING')
  returning id into v_dg1;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg1, v_user_a), (v_dg1, v_user_b);

  -- req2: min_participants=4，user_d/user_e 兩人（用來測 DISAGREE 立即 REJECTED）
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user_d, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 4, 4, 'REQUESTING')
  returning * into v_req2;
  insert into request_member (request_id, user_id, role, status) values
    (v_req2.id, v_user_d, 'OWNER', 'JOINED'), (v_req2.id, v_user_e, 'MEMBER', 'JOINED');

  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req2.id, 2, now() + interval '10 minutes', 'PENDING')
  returning id into v_dg2;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg2, v_user_d), (v_dg2, v_user_e);

  -- req3: 過期窗口 (CONSENT_WINDOW_CLOSED)
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user_f, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 4, 4, 'REQUESTING')
  returning * into v_req3;
  insert into request_member (request_id, user_id, role, status) values (v_req3.id, v_user_f, 'OWNER', 'JOINED');

  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req3.id, 2, now() - interval '1 minute', 'PENDING')
  returning id into v_dg3;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg3, v_user_f);

  -- req4: target_size (3) 不低於 min_participants (3) —— ERD 備註 21 防呆用的壞資料
  insert into match_request (owner_id, activity_type_id, campus_location_id, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_user_g, v_act_type_id, v_loc_id, now(), now() + interval '2 hours', 3, 3, 'REQUESTING')
  returning * into v_req4;
  insert into request_member (request_id, user_id, role, status) values (v_req4.id, v_user_g, 'OWNER', 'JOINED');

  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req4.id, 3, now() + interval '10 minutes', 'PENDING')
  returning id into v_dg4;
  insert into downgrade_consent (downgrade_request_id, user_id) values (v_dg4, v_user_g);

  update fixtures set
    user_a_id = v_user_a, user_b_id = v_user_b, user_c_id = v_user_c,
    user_d_id = v_user_d, user_e_id = v_user_e, user_f_id = v_user_f, user_g_id = v_user_g,
    act_type_id = v_act_type_id, loc_id = v_loc_id,
    req1_id = v_req1.id, req2_id = v_req2.id, req3_id = v_req3.id, req4_id = v_req4.id,
    dg1_id = v_dg1, dg2_id = v_dg2, dg3_id = v_dg3, dg4_id = v_dg4;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. FORBIDDEN — user_c 不在 dg1 的 downgrade_consent 名單裡
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_c_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select respond_downgrade(%L, true)$sql$, (select dg1_id from fixtures)),
  'FORBIDDEN',
  '非受詢問成員呼叫 respond_downgrade 應被 FORBIDDEN 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. 部分同意 — user_a AGREE，user_b 尚未回應，dg1 應仍是 PENDING
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_a_id::text from fixtures), true);
  perform respond_downgrade((select dg1_id from fixtures), true);
end $$;

select is(
  (select status::text from downgrade_request where id = (select dg1_id from fixtures)),
  'PENDING',
  '只有一人 AGREE 時 downgrade_request 應仍是 PENDING（尚未全員同意）'
);

-- -----------------------------------------------------------------------------
-- 3. ALREADY_RESPONDED — user_a 對同一個 downgrade_request 再回應一次
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select respond_downgrade(%L, true)$sql$, (select dg1_id from fixtures)),
  'ALREADY_RESPONDED',
  '同一使用者對同一 downgrade_request 重複回應應被 ALREADY_RESPONDED 擋下'
);

-- -----------------------------------------------------------------------------
-- 4. 全員同意 — user_b 也 AGREE，dg1 應轉為 APPROVED
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_b_id::text from fixtures), true);
  perform respond_downgrade((select dg1_id from fixtures), true);
end $$;

select is(
  (select status::text from downgrade_request where id = (select dg1_id from fixtures)),
  'APPROVED',
  '全員 AGREE 後 downgrade_request 應轉為 APPROVED'
);

-- -----------------------------------------------------------------------------
-- 5. 任一人 DISAGREE — dg2 應立即 REJECTED，不必等 user_e 回應
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_d_id::text from fixtures), true);
  perform respond_downgrade((select dg2_id from fixtures), false);
end $$;

select is(
  (select status::text from downgrade_request where id = (select dg2_id from fixtures)),
  'REJECTED',
  '任一人 DISAGREE 應立即轉為 REJECTED，不必等其他成員回應'
);

-- -----------------------------------------------------------------------------
-- 6. CONSENT_WINDOW_CLOSED — dg3 的 expire_at 已過
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_f_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select respond_downgrade(%L, true)$sql$, (select dg3_id from fixtures)),
  'CONSENT_WINDOW_CLOSED',
  '已過 10 分鐘 CONSENT_WINDOW 的 downgrade_request 應被 CONSENT_WINDOW_CLOSED 擋下'
);

-- -----------------------------------------------------------------------------
-- 7. INVALID_INPUT — ERD 設計備註 21：target_size 必須低於原 min_participants，
--    dg4 是刻意寫壞的資料 (target_size = min_participants)，回應 RPC 應用層擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_g_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select respond_downgrade(%L, true)$sql$, (select dg4_id from fixtures)),
  'INVALID_INPUT',
  'target_size 未低於原 min_participants 的壞資料應被 INVALID_INPUT 擋下（ERD 設計備註 21）'
);

select * from finish();

rollback;
