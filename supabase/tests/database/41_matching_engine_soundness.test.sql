-- =============================================================================
-- pgTAP Test — 配對引擎健壯性與邊界修復 (Matching Engine Soundness) — v1.45
--
-- 涵蓋 8 大焦點場景（各自以獨立 campus 隔離）：
--   ① 全體人數上限保護：候選之 max_participants 不被後續候選超收灌爆
--   ② 全體人數下限保護：候選之 min_participants 未獲滿足時絕不提早成團
--   ③ 運動等級傳遞性保護：A-B 相容、A-C 相容，但 B-C 跨級不相容時，絕不同時撮合
--   ④ 讀書目標一致性保護：Wildcard 種子吸納科目 A 後，互斥科目 B 絕不同局
--   ⑤ 受邀成員雙向封鎖隔離：下探至 request_member，受邀朋友封鎖對方成員即阻擋撮合
--   ⑥ 延遲撮合與過期時間防護：排除已過期或交集落入過去之無效時段
--   ⑦ 純邀請朋友達標自足成團：單筆 Request 湊滿自身 min_participants 直接成團建立 Activity
--   ⑧ 跨需求同一使用者防重：同一使用者跨需求重複存在時阻擋合併，防止主鍵衝突
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(11);

-- -----------------------------------------------------------------------------
-- 0. Setup Fixtures Table
-- -----------------------------------------------------------------------------

create temp table fixtures (
  tennis_type_id    uuid,
  badminton_type_id uuid,
  study_type_id     uuid,

  -- ① 全體人數上限保護
  campus_s1   text,
  s1_req_a    uuid, s1_req_b uuid, s1_req_c uuid,

  -- ② 全體人數下限保護
  campus_s2   text,
  s2_req_a    uuid, s2_req_b uuid,

  -- ③ 運動等級傳遞性保護
  campus_s3   text,
  s3_req_a    uuid, s3_req_b uuid, s3_req_c uuid,

  -- ④ 讀書目標一致性保護
  campus_s4   text,
  s4_req_a    uuid, s4_req_b uuid, s4_req_c uuid,

  -- ⑤ 受邀成員雙向封鎖隔離
  campus_s5   text,
  s5_req_a    uuid, s5_req_b uuid,

  -- ⑥ 延遲撮合與過期時間防護
  campus_s6   text,
  s6_req_past uuid, s6_req_valid uuid,

  -- ⑦ 純邀請朋友達標自足成團
  campus_s7   text,
  s7_req      uuid,

  -- ⑧ 跨需求同一使用者防重
  campus_s8   text,
  s8_req_a    uuid, s8_req_b uuid
);
insert into fixtures default values;

do $setup$
declare
  v_tennis_id    uuid;
  v_badminton_id uuid;
  v_study_id     uuid;
  v_now          timestamptz := now();

  -- ① 全體人數上限保護
  v_s1_campus text := 'S1_MAX_CAP';
  v_s1_u1     uuid := gen_random_uuid();
  v_s1_u2     uuid := gen_random_uuid();
  v_s1_u3     uuid := gen_random_uuid();
  v_s1_ra     match_request;
  v_s1_rb     match_request;
  v_s1_rc     match_request;

  -- ② 全體人數下限保護
  v_s2_campus text := 'S2_MIN_FLOOR';
  v_s2_u1     uuid := gen_random_uuid();
  v_s2_u2     uuid := gen_random_uuid();
  v_s2_ra     match_request;
  v_s2_rb     match_request;

  -- ③ 運動等級傳遞性保護
  v_s3_campus text := 'S3_SPORT_TRANS';
  v_s3_u1     uuid := gen_random_uuid();
  v_s3_u2     uuid := gen_random_uuid();
  v_s3_u3     uuid := gen_random_uuid();
  v_s3_ra     match_request;
  v_s3_rb     match_request;
  v_s3_rc     match_request;

  -- ④ 讀書目標一致性保護
  v_s4_campus text := 'S4_STUDY_TARGET';
  v_s4_u1     uuid := gen_random_uuid();
  v_s4_u2     uuid := gen_random_uuid();
  v_s4_u3     uuid := gen_random_uuid();
  v_s4_ra     match_request;
  v_s4_rb     match_request;
  v_s4_rc     match_request;

  -- ⑤ 受邀成員雙向封鎖隔離
  v_s5_campus text := 'S5_MEMBER_BLOCK';
  v_s5_u1     uuid := gen_random_uuid();
  v_s5_u2     uuid := gen_random_uuid();
  v_s5_u3     uuid := gen_random_uuid();
  v_s5_ra     match_request;
  v_s5_rb     match_request;

  -- ⑥ 延遲撮合與過期時間防護
  v_s6_campus text := 'S6_EXPIRED_WINDOW';
  v_s6_u1     uuid := gen_random_uuid();
  v_s6_u2     uuid := gen_random_uuid();
  v_s6_ra     match_request;
  v_s6_rb     match_request;

  -- ⑦ 純邀請朋友達標自足成團
  v_s7_campus text := 'S7_SELF_SUFFICIENT';
  v_s7_u1     uuid := gen_random_uuid();
  v_s7_u2     uuid := gen_random_uuid();
  v_s7_u3     uuid := gen_random_uuid();
  v_s7_u4     uuid := gen_random_uuid();
  v_s7_ra     match_request;

  -- ⑧ 跨需求同一使用者防重
  v_s8_campus text := 'S8_DUPLICATE_USER';
  v_s8_u1     uuid := gen_random_uuid();
  v_s8_u2     uuid := gen_random_uuid();
  v_s8_ra     match_request;
  v_s8_rb     match_request;

begin
  select id into v_tennis_id from activity_type where name = '網球' limit 1;
  select id into v_badminton_id from activity_type where name = '羽球' limit 1;
  select id into v_study_id from activity_type where name = '讀書' limit 1;

  -- 註冊各場景之活動地點
  insert into location (school, campus, name, is_active) values
    ('NYCU', v_s1_campus, 'S1地點', true),
    ('NYCU', v_s2_campus, 'S2地點', true),
    ('NYCU', v_s3_campus, 'S3地點', true),
    ('NYCU', v_s4_campus, 'S4地點', true),
    ('NYCU', v_s5_campus, 'S5地點', true),
    ('NYCU', v_s6_campus, 'S6地點', true),
    ('NYCU', v_s7_campus, 'S7地點', true),
    ('NYCU', v_s8_campus, 'S8地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- --------------------------------------------------------------------------
  -- ① 全體人數上限保護：
  --    種子 A：1 人，min 2, max 5
  --    候選 B：1 人，min 2, max 2  (上限為 2 人)
  --    候選 C：1 人，min 2, max 5
  --    當 A 與 B 合併後（累積 2 人），累積 max 縮緊至 2；C 嘗試併入會使人數為 3 (> 2)，應被排除。
  --    最終應成立 1 場 2 人活動 (A+B)，C 維持 REQUESTING。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s1_u1, 's1_u1@nycu.edu.tw'), (v_s1_u2, 's1_u2@nycu.edu.tw'), (v_s1_u3, 's1_u3@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s1_u1, 's1_u1@nycu.edu.tw', 'NYCU', 'S1 U1', 'https://avatar.s1u1', 'UNDERGRAD', 's1_u1_ig'),
    (v_s1_u2, 's1_u2@nycu.edu.tw', 'NYCU', 'S1 U2', 'https://avatar.s1u2', 'UNDERGRAD', 's1_u2_ig'),
    (v_s1_u3, 's1_u3@nycu.edu.tw', 'NYCU', 'S1 U3', 'https://avatar.s1u3', 'UNDERGRAD', 's1_u3_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values (v_s1_u1, v_tennis_id, 'NYCU', v_s1_campus, v_now, v_now + interval '2 hours', 2, 5, 'REQUESTING', v_now - interval '30 seconds')
  returning * into v_s1_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s1_ra.id, v_s1_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values (v_s1_u2, v_tennis_id, 'NYCU', v_s1_campus, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', v_now - interval '20 seconds')
  returning * into v_s1_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s1_rb.id, v_s1_u2, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, created_at)
  values (v_s1_u3, v_tennis_id, 'NYCU', v_s1_campus, v_now, v_now + interval '2 hours', 2, 5, 'REQUESTING', v_now - interval '10 seconds')
  returning * into v_s1_rc;
  insert into request_member (request_id, user_id, role, status) values (v_s1_rc.id, v_s1_u3, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ② 全體人數下限保護：
  --    種子 A：1 人，min 2, max 6
  --    候選 B：1 人，min 4, max 6  (下限要求 4 人)
  --    當僅有 A + B (共 2 人) 時，因未達 B 的 min (4)，兩者絕不提早成團，維持 REQUESTING。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s2_u1, 's2_u1@nycu.edu.tw'), (v_s2_u2, 's2_u2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s2_u1, 's2_u1@nycu.edu.tw', 'NYCU', 'S2 U1', 'https://avatar.s2u1', 'UNDERGRAD', 's2_u1_ig'),
    (v_s2_u2, 's2_u2@nycu.edu.tw', 'NYCU', 'S2 U2', 'https://avatar.s2u2', 'UNDERGRAD', 's2_u2_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s2_u1, v_badminton_id, 'NYCU', v_s2_campus, v_now, v_now + interval '2 hours', 2, 6, 'REQUESTING')
  returning * into v_s2_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s2_ra.id, v_s2_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s2_u2, v_badminton_id, 'NYCU', v_s2_campus, v_now, v_now + interval '2 hours', 4, 6, 'REQUESTING')
  returning * into v_s2_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s2_rb.id, v_s2_u2, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ③ 運動等級傳遞性保護：
  --    種子 A：羽球 LEVEL_6_7 (num=2, min=2, max=4)
  --    候選 B：羽球 LEVEL_1_5 (num=1, min=2, max=4) -> 與 A 相差 1，相容
  --    候選 C：羽球 LEVEL_8_10 (num=3, min=2, max=4) -> 與 A 相差 1，但與 B 相差 2 (跨級不相容)
  --    A 與 B 合併後，C 比對累積集合中的 B 判定不相容，C 排除，C 維持 REQUESTING。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s3_u1, 's3_u1@nycu.edu.tw'), (v_s3_u2, 's3_u2@nycu.edu.tw'), (v_s3_u3, 's3_u3@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s3_u1, 's3_u1@nycu.edu.tw', 'NYCU', 'S3 U1', 'https://avatar.s3u1', 'UNDERGRAD', 's3_u1_ig'),
    (v_s3_u2, 's3_u2@nycu.edu.tw', 'NYCU', 'S3 U2', 'https://avatar.s3u2', 'UNDERGRAD', 's3_u2_ig'),
    (v_s3_u3, 's3_u3@nycu.edu.tw', 'NYCU', 'S3 U3', 'https://avatar.s3u3', 'UNDERGRAD', 's3_u3_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level, created_at)
  values (v_s3_u1, v_badminton_id, 'NYCU', v_s3_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'LEVEL_6_7', v_now - interval '30 seconds')
  returning * into v_s3_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s3_ra.id, v_s3_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level, created_at)
  values (v_s3_u2, v_badminton_id, 'NYCU', v_s3_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'LEVEL_1_5', v_now - interval '20 seconds')
  returning * into v_s3_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s3_rb.id, v_s3_u2, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, sport_level, created_at)
  values (v_s3_u3, v_badminton_id, 'NYCU', v_s3_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', 'LEVEL_8_10', v_now - interval '10 seconds')
  returning * into v_s3_rc;
  insert into request_member (request_id, user_id, role, status) values (v_s3_rc.id, v_s3_u3, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ④ 讀書目標一致性保護：
  --    種子 A：study_target_normalized = null (wildcard)
  --    候選 B：study_target_normalized = '微積分'
  --    候選 C：study_target_normalized = '線性代數'
  --    A 與 B 合併後，C 比對 B 發現科目互斥，C 排除，C 維持 REQUESTING。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s4_u1, 's4_u1@nycu.edu.tw'), (v_s4_u2, 's4_u2@nycu.edu.tw'), (v_s4_u3, 's4_u3@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s4_u1, 's4_u1@nycu.edu.tw', 'NYCU', 'S4 U1', 'https://avatar.s4u1', 'UNDERGRAD', 's4_u1_ig'),
    (v_s4_u2, 's4_u2@nycu.edu.tw', 'NYCU', 'S4 U2', 'https://avatar.s4u2', 'UNDERGRAD', 's4_u2_ig'),
    (v_s4_u3, 's4_u3@nycu.edu.tw', 'NYCU', 'S4 U3', 'https://avatar.s4u3', 'UNDERGRAD', 's4_u3_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized, created_at)
  values (v_s4_u1, v_study_id, 'NYCU', v_s4_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', null, null, v_now - interval '30 seconds')
  returning * into v_s4_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s4_ra.id, v_s4_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized, created_at)
  values (v_s4_u2, v_study_id, 'NYCU', v_s4_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', '微積分', '微積分', v_now - interval '20 seconds')
  returning * into v_s4_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s4_rb.id, v_s4_u2, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized, created_at)
  values (v_s4_u3, v_study_id, 'NYCU', v_s4_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING', '線性代數', '線性代數', v_now - interval '10 seconds')
  returning * into v_s4_rc;
  insert into request_member (request_id, user_id, role, status) values (v_s4_rc.id, v_s4_u3, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑤ 受邀成員雙向封鎖隔離：
  --    Request A 由 U1 建立，U2 (受邀朋友) 加入 (JOINED)。
  --    Request B 由 U3 建立。
  --    U2 與 U3 互設/單向封鎖（例如 U2 封鎖 U3）。
  --    雖然 Owner U1 與 Owner U3 沒有互相封鎖，引擎下探 request_member 阻擋撮合。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s5_u1, 's5_u1@nycu.edu.tw'), (v_s5_u2, 's5_u2@nycu.edu.tw'), (v_s5_u3, 's5_u3@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s5_u1, 's5_u1@nycu.edu.tw', 'NYCU', 'S5 U1', 'https://avatar.s5u1', 'UNDERGRAD', 's5_u1_ig'),
    (v_s5_u2, 's5_u2@nycu.edu.tw', 'NYCU', 'S5 U2', 'https://avatar.s5u2', 'UNDERGRAD', 's5_u2_ig'),
    (v_s5_u3, 's5_u3@nycu.edu.tw', 'NYCU', 'S5 U3', 'https://avatar.s5u3', 'UNDERGRAD', 's5_u3_ig');

  insert into user_block (blocker_id, blocked_id) values (v_s5_u2, v_s5_u3);

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s5_u1, v_badminton_id, 'NYCU', v_s5_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_s5_ra;
  insert into request_member (request_id, user_id, role, status) values
    (v_s5_ra.id, v_s5_u1, 'OWNER', 'JOINED'),
    (v_s5_ra.id, v_s5_u2, 'MEMBER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s5_u3, v_badminton_id, 'NYCU', v_s5_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_s5_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s5_rb.id, v_s5_u3, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑥ 延遲撮合與過期時間防護：
  --    Request Past：latest_start 落在過去（已過期）。
  --    Request Valid：時間窗在未來。
  --    驗證引擎排除過期需求，不撮合成團。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s6_u1, 's6_u1@nycu.edu.tw'), (v_s6_u2, 's6_u2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s6_u1, 's6_u1@nycu.edu.tw', 'NYCU', 'S6 U1', 'https://avatar.s6u1', 'UNDERGRAD', 's6_u1_ig'),
    (v_s6_u2, 's6_u2@nycu.edu.tw', 'NYCU', 'S6 U2', 'https://avatar.s6u2', 'UNDERGRAD', 's6_u2_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s6_u1, v_badminton_id, 'NYCU', v_s6_campus, v_now - interval '3 hours', v_now - interval '1 hour', 2, 4, 'REQUESTING')
  returning * into v_s6_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s6_ra.id, v_s6_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s6_u2, v_badminton_id, 'NYCU', v_s6_campus, v_now + interval '10 minutes', v_now + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_s6_rb;
  insert into request_member (request_id, user_id, role, status) values (v_s6_rb.id, v_s6_u2, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑦ 純邀請朋友達標自足成團：
  --    單筆 Request 由 U1 發起，並邀請 U2, U3, U4（共 4 位 JOINED 成員）。
  --    min_participants = 4, max_participants = 4。該校區無其他 Request。
  --    驗證引擎單獨將該 Request 轉為 MATCHED，建立 Activity，不被「需要 >= 2 筆 Request」卡死。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s7_u1, 's7_u1@nycu.edu.tw'), (v_s7_u2, 's7_u2@nycu.edu.tw'),
    (v_s7_u3, 's7_u3@nycu.edu.tw'), (v_s7_u4, 's7_u4@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s7_u1, 's7_u1@nycu.edu.tw', 'NYCU', 'S7 U1', 'https://avatar.s7u1', 'UNDERGRAD', 's7_u1_ig'),
    (v_s7_u2, 's7_u2@nycu.edu.tw', 'NYCU', 'S7 U2', 'https://avatar.s7u2', 'UNDERGRAD', 's7_u2_ig'),
    (v_s7_u3, 's7_u3@nycu.edu.tw', 'NYCU', 'S7 U3', 'https://avatar.s7u3', 'UNDERGRAD', 's7_u3_ig'),
    (v_s7_u4, 's7_u4@nycu.edu.tw', 'NYCU', 'S7 U4', 'https://avatar.s7u4', 'UNDERGRAD', 's7_u4_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s7_u1, v_badminton_id, 'NYCU', v_s7_campus, v_now, v_now + interval '2 hours', 4, 4, 'REQUESTING')
  returning * into v_s7_ra;
  insert into request_member (request_id, user_id, role, status) values
    (v_s7_ra.id, v_s7_u1, 'OWNER', 'JOINED'),
    (v_s7_ra.id, v_s7_u2, 'MEMBER', 'JOINED'),
    (v_s7_ra.id, v_s7_u3, 'MEMBER', 'JOINED'),
    (v_s7_ra.id, v_s7_u4, 'MEMBER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑧ 跨需求同一使用者防重：
  --    Request A 由 U1 擁有。
  --    Request B 由 U2 擁有，但 U1 亦是 Request B 的已加入成員。
  --    驗證引擎拒絕合併兩筆需求，防止同一使用者重複進入活動。
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_s8_u1, 's8_u1@nycu.edu.tw'), (v_s8_u2, 's8_u2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_s8_u1, 's8_u1@nycu.edu.tw', 'NYCU', 'S8 U1', 'https://avatar.s8u1', 'UNDERGRAD', 's8_u1_ig'),
    (v_s8_u2, 's8_u2@nycu.edu.tw', 'NYCU', 'S8 U2', 'https://avatar.s8u2', 'UNDERGRAD', 's8_u2_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s8_u1, v_tennis_id, 'NYCU', v_s8_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_s8_ra;
  insert into request_member (request_id, user_id, role, status) values (v_s8_ra.id, v_s8_u1, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_s8_u2, v_tennis_id, 'NYCU', v_s8_campus, v_now, v_now + interval '2 hours', 2, 4, 'REQUESTING')
  returning * into v_s8_rb;
  insert into request_member (request_id, user_id, role, status) values
    (v_s8_rb.id, v_s8_u2, 'OWNER', 'JOINED'),
    (v_s8_rb.id, v_s8_u1, 'MEMBER', 'JOINED');

  -- 更新 fixtures 快照
  update fixtures set
    tennis_type_id = v_tennis_id, badminton_type_id = v_badminton_id, study_type_id = v_study_id,
    campus_s1 = v_s1_campus, s1_req_a = v_s1_ra.id, s1_req_b = v_s1_rb.id, s1_req_c = v_s1_rc.id,
    campus_s2 = v_s2_campus, s2_req_a = v_s2_ra.id, s2_req_b = v_s2_rb.id,
    campus_s3 = v_s3_campus, s3_req_a = v_s3_ra.id, s3_req_b = v_s3_rb.id, s3_req_c = v_s3_rc.id,
    campus_s4 = v_s4_campus, s4_req_a = v_s4_ra.id, s4_req_b = v_s4_rb.id, s4_req_c = v_s4_rc.id,
    campus_s5 = v_s5_campus, s5_req_a = v_s5_ra.id, s5_req_b = v_s5_rb.id,
    campus_s6 = v_s6_campus, s6_req_past = v_s6_ra.id, s6_req_valid = v_s6_rb.id,
    campus_s7 = v_s7_campus, s7_req = v_s7_ra.id,
    campus_s8 = v_s8_campus, s8_req_a = v_s8_ra.id, s8_req_b = v_s8_rb.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 執行一次 Matching Engine
-- 預期成功成團/成配對：
--   ① 成立 1 場 (A+B 進入 pending_confirmation 或活動，C 排除)
--   ② 0 場 (未達下限，維持 REQUESTING)
--   ③ 成立 1 場 (A+B 進入配對，C 排除)
--   ④ 成立 1 場 (A+B 進入配對，C 排除)
--   ⑤ 0 場 (受邀朋友封鎖，維持 REQUESTING)
--   ⑥ 0 場 (過期需求排除，維持 REQUESTING)
--   ⑦ 成立 1 場 (自足需求直接建立 MATCHED Activity)
--   ⑧ 0 場 (同使用者防重，維持 REQUESTING)
-- -----------------------------------------------------------------------------

select ok(fn_run_matching_engine() >= 4, '配對引擎執行成功，涵蓋各情境之獨立處理');

-- -----------------------------------------------------------------------------
-- ① 驗證：全體人數上限保護
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s1_req_c from fixtures)),
  'REQUESTING',
  '情境①：候選 C 不得被塞入已達 max_participants (2) 的團體，應維持 REQUESTING'
);

-- -----------------------------------------------------------------------------
-- ② 驗證：全體人數下限保護
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_request
    where id in ((select s2_req_a from fixtures), (select s2_req_b from fixtures))
      and status = 'REQUESTING'),
  2,
  '情境②：候選 B 要求 min=4，在累積僅有 2 人時絕不提早成團，兩者維持 REQUESTING'
);

-- -----------------------------------------------------------------------------
-- ③ 驗證：運動等級傳遞性保護
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s3_req_c from fixtures)),
  'REQUESTING',
  '情境③：C (8–10級) 與 B (1–5級) 跨級不相容，即使 A 同時相容兩者，C 亦不得與 B 同局，應維持 REQUESTING'
);

-- -----------------------------------------------------------------------------
-- ④ 驗證：讀書目標一致性保護
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s4_req_c from fixtures)),
  'REQUESTING',
  '情境④：Wildcard 種子吸納微積分後，線性代數 C 不得被併入，應維持 REQUESTING'
);

-- -----------------------------------------------------------------------------
-- ⑤ 驗證：受邀成員雙向封鎖隔離
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_request
    where id in ((select s5_req_a from fixtures), (select s5_req_b from fixtures))
      and status = 'REQUESTING'),
  2,
  '情境⑤：下探至受邀成員封鎖（A2 封鎖 B1），即使發起人 A1 與 B1 未封鎖，兩需求亦不得撮合'
);

-- -----------------------------------------------------------------------------
-- ⑥ 驗證：延遲撮合與過期時間防護
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s6_req_past from fixtures)),
  'REQUESTING',
  '情境⑥：已過期之需求不被撮合，維持 REQUESTING 等待清理排程'
);

-- -----------------------------------------------------------------------------
-- ⑦ 驗證：純邀請朋友達標自足成團
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s7_req from fixtures)),
  'MATCHED',
  '情境⑦：純邀請朋友達標（min=4且成員4人）的單筆需求，直接建立 Activity 並轉為 MATCHED'
);

select is(
  (select count(*)::int from activity_member am
    join activity a on a.id = am.activity_id
   where a.school = 'NYCU' and a.campus = (select campus_s7 from fixtures) and a.status = 'MATCHED'),
  4,
  '情境⑦：自足成團建立的 Activity 應包含該需求的全部 4 位成員'
);

-- -----------------------------------------------------------------------------
-- ⑧ 驗證：跨需求同一使用者防重
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_request
    where id in ((select s8_req_a from fixtures), (select s8_req_b from fixtures))
      and status = 'REQUESTING'),
  2,
  '情境⑧：同一使用者跨需求重複存在時，引擎拒絕合併，防止主鍵衝突'
);

-- -----------------------------------------------------------------------------
-- 9. fn_create_activity_from_requests 防禦性檢查單元測試
-- -----------------------------------------------------------------------------

select throws_ok(
  format('select fn_create_activity_from_requests(array[''%s''::uuid, ''%s''::uuid])',
    (select s1_req_c from fixtures), (select s2_req_a from fixtures)),
  'INTERNAL_ERROR',
  'fn_create_activity_from_requests 傳入不同 campus 或 activity_type 應防禦性拋出 MISMATCHED_ACTIVITY_TYPE_OR_CAMPUS'
);

select * from finish();

rollback;
