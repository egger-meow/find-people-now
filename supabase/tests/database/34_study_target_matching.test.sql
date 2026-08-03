-- =============================================================================
-- pgTAP Test — 讀書「同伴目標」自由文字比對 (v1.35)
-- =============================================================================
-- 涵蓋（各自用不同 campus 隔離，避免互相撮合）：
--   ① 全形括號/前後空白正規化後相同 → 應配對（兩邊原文不同，正規化後相同）
--   ② 大小寫正規化後相同（TOEFL vs toefl）→ 應配對
--   ③ null wildcard：一方未填，應可跟任何指定字串配對
--   ④ 正規化後不同字串 → 不應配對
--   ⑤ 課名/考試名稱字串剛好相同（語意完全不同，但字串一致）→ 應配對，驗證
--      系統是純字串比對、不理解語意（刻意的設計限制）
--   ⑥ study_target（原文）與 study_target_normalized 兩欄位分開存：透過
--      create_request 驗證同一筆 insert 後兩欄位確實不同（輸入含全形符號時），
--      原文欄位完整保留使用者輸入，撮合邏輯只受 normalized 欄位影響
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(9);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  study_type_id  uuid,
  campus_t1      text, t1_a_id uuid, t1_b_id uuid,
  campus_t2      text, t2_a_id uuid, t2_b_id uuid,
  campus_t3      text, t3_a_id uuid, t3_b_id uuid,
  campus_t4      text, t4_a_id uuid, t4_b_id uuid,
  campus_t5      text, t5_a_id uuid, t5_b_id uuid,
  campus_t6      text,
  t6_user_id     uuid,
  t6_req_id      uuid
);
insert into fixtures default values;

do $setup$
declare
  v_study_type_id uuid;

  v_campus_t1 text := 'ST1區';
  v_campus_t2 text := 'ST2區';
  v_campus_t3 text := 'ST3區';
  v_campus_t4 text := 'ST4區';
  v_campus_t5 text := 'ST5區';
  v_campus_t6 text := 'ST6區';

  v_now timestamptz := now();

  v_t1_a_id uuid := gen_random_uuid();
  v_t1_b_id uuid := gen_random_uuid();
  v_t1_a_req match_request;
  v_t1_b_req match_request;

  v_t2_a_id uuid := gen_random_uuid();
  v_t2_b_id uuid := gen_random_uuid();
  v_t2_a_req match_request;
  v_t2_b_req match_request;

  v_t3_a_id uuid := gen_random_uuid();
  v_t3_b_id uuid := gen_random_uuid();
  v_t3_a_req match_request;
  v_t3_b_req match_request;

  v_t4_a_id uuid := gen_random_uuid();
  v_t4_b_id uuid := gen_random_uuid();
  v_t4_a_req match_request;
  v_t4_b_req match_request;

  v_t5_a_id uuid := gen_random_uuid();
  v_t5_b_id uuid := gen_random_uuid();
  v_t5_a_req match_request;
  v_t5_b_req match_request;

  v_t6_user_id uuid := gen_random_uuid();
begin
  select id into v_study_type_id from activity_type where name = '讀書' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus_t1, 'ST1測試地點', true),
    ('NYCU', v_campus_t2, 'ST2測試地點', true),
    ('NYCU', v_campus_t3, 'ST3測試地點', true),
    ('NYCU', v_campus_t4, 'ST4測試地點', true),
    ('NYCU', v_campus_t5, 'ST5測試地點', true),
    ('NYCU', v_campus_t6, 'ST6測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- --------------------------------------------------------------------------
  -- ① 全形括號/前後空白：A 原文「  微積分（一）  」、B 原文「微積分(一)」
  --    正規化後應相同 → 應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_t1_a_id, 't1_a@nycu.edu.tw'), (v_t1_b_id, 't1_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t1_a_id, 't1_a@nycu.edu.tw', 'NYCU', 'T1 A', 'https://avatar.t1a', 'UNDERGRAD', 't1_a_ig'),
    (v_t1_b_id, 't1_b@nycu.edu.tw', 'NYCU', 'T1 B', 'https://avatar.t1b', 'UNDERGRAD', 't1_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t1_a_id, v_study_type_id, 'NYCU', v_campus_t1, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '  微積分（一）  ', fn_normalize_study_target('  微積分（一）  '))
  returning * into v_t1_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_t1_a_req.id, v_t1_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t1_b_id, v_study_type_id, 'NYCU', v_campus_t1, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '微積分(一)', fn_normalize_study_target('微積分(一)'))
  returning * into v_t1_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_t1_b_req.id, v_t1_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ② 大小寫：A「TOEFL」、B「toefl」→ 正規化後應相同 → 應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_t2_a_id, 't2_a@nycu.edu.tw'), (v_t2_b_id, 't2_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t2_a_id, 't2_a@nycu.edu.tw', 'NYCU', 'T2 A', 'https://avatar.t2a', 'UNDERGRAD', 't2_a_ig'),
    (v_t2_b_id, 't2_b@nycu.edu.tw', 'NYCU', 'T2 B', 'https://avatar.t2b', 'UNDERGRAD', 't2_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t2_a_id, v_study_type_id, 'NYCU', v_campus_t2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          'TOEFL', fn_normalize_study_target('TOEFL'))
  returning * into v_t2_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_t2_a_req.id, v_t2_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t2_b_id, v_study_type_id, 'NYCU', v_campus_t2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          'toefl', fn_normalize_study_target('toefl'))
  returning * into v_t2_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_t2_b_req.id, v_t2_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ③ null wildcard：A 未填、B「線性代數」→ 應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_t3_a_id, 't3_a@nycu.edu.tw'), (v_t3_b_id, 't3_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t3_a_id, 't3_a@nycu.edu.tw', 'NYCU', 'T3 A', 'https://avatar.t3a', 'UNDERGRAD', 't3_a_ig'),
    (v_t3_b_id, 't3_b@nycu.edu.tw', 'NYCU', 'T3 B', 'https://avatar.t3b', 'UNDERGRAD', 't3_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t3_a_id, v_study_type_id, 'NYCU', v_campus_t3, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', null, null)
  returning * into v_t3_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_t3_a_req.id, v_t3_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t3_b_id, v_study_type_id, 'NYCU', v_campus_t3, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '線性代數', fn_normalize_study_target('線性代數'))
  returning * into v_t3_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_t3_b_req.id, v_t3_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ④ 不同字串：A「微積分」、B「普通物理」→ 不應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_t4_a_id, 't4_a@nycu.edu.tw'), (v_t4_b_id, 't4_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t4_a_id, 't4_a@nycu.edu.tw', 'NYCU', 'T4 A', 'https://avatar.t4a', 'UNDERGRAD', 't4_a_ig'),
    (v_t4_b_id, 't4_b@nycu.edu.tw', 'NYCU', 'T4 B', 'https://avatar.t4b', 'UNDERGRAD', 't4_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t4_a_id, v_study_type_id, 'NYCU', v_campus_t4, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '微積分', fn_normalize_study_target('微積分'))
  returning * into v_t4_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_t4_a_req.id, v_t4_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t4_b_id, v_study_type_id, 'NYCU', v_campus_t4, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '普通物理', fn_normalize_study_target('普通物理'))
  returning * into v_t4_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_t4_b_req.id, v_t4_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑤ 課名 vs 考試名稱字串剛好相同：A 打「多益」意指要準備多益考試、
  --    B 剛好也打「多益」（語意可能完全不同，但字串一致）→ 應配對，
  --    驗證系統純字串比對、不理解語意
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_t5_a_id, 't5_a@nycu.edu.tw'), (v_t5_b_id, 't5_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t5_a_id, 't5_a@nycu.edu.tw', 'NYCU', 'T5 A', 'https://avatar.t5a', 'UNDERGRAD', 't5_a_ig'),
    (v_t5_b_id, 't5_b@nycu.edu.tw', 'NYCU', 'T5 B', 'https://avatar.t5b', 'UNDERGRAD', 't5_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t5_a_id, v_study_type_id, 'NYCU', v_campus_t5, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '多益', fn_normalize_study_target('多益'))
  returning * into v_t5_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_t5_a_req.id, v_t5_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, study_target, study_target_normalized)
  values (v_t5_b_id, v_study_type_id, 'NYCU', v_campus_t5, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING',
          '多益', fn_normalize_study_target('多益'))
  returning * into v_t5_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_t5_b_req.id, v_t5_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ⑥ 原文/正規化分開存：透過 create_request 驗證的使用者
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values (v_t6_user_id, 't6_user@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_t6_user_id, 't6_user@nycu.edu.tw', 'NYCU', 'T6 User', 'https://avatar.t6', 'UNDERGRAD', 't6_ig');

  update fixtures set
    study_type_id = v_study_type_id,
    campus_t1 = v_campus_t1, t1_a_id = v_t1_a_req.id, t1_b_id = v_t1_b_req.id,
    campus_t2 = v_campus_t2, t2_a_id = v_t2_a_req.id, t2_b_id = v_t2_b_req.id,
    campus_t3 = v_campus_t3, t3_a_id = v_t3_a_req.id, t3_b_id = v_t3_b_req.id,
    campus_t4 = v_campus_t4, t4_a_id = v_t4_a_req.id, t4_b_id = v_t4_b_req.id,
    campus_t5 = v_campus_t5, t5_a_id = v_t5_a_req.id, t5_b_id = v_t5_b_req.id,
    campus_t6 = v_campus_t6, t6_user_id = v_t6_user_id;
end;
$setup$;

grant select, update on fixtures to authenticated;

-- -----------------------------------------------------------------------------
-- ⑥ 呼叫 create_request（讀書）帶全形符號+前後空白的 p_study_target，
--    驗證 study_target（原文）與 study_target_normalized（正規化）分開存
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$
declare
  v_req match_request;
begin
  perform set_config('request.jwt.claim.sub', (select t6_user_id::text from fixtures), true);
  v_req := create_request(
    p_activity_type_id := (select study_type_id from fixtures),
    p_campus            := (select campus_t6 from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 4,
    p_allow_downgrade        := false,
    p_skill_level             := null,
    p_study_target             := '  微積分（一）　'
  );
  update fixtures set t6_req_id = v_req.id;
end $$;

reset role;

-- -----------------------------------------------------------------------------
-- 執行一次 Matching Engine，同時處理 ①②③④⑤
-- 預期：①1 +②1 +③1 +④0 +⑤1 ＝ 4
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 4, 'study_target 相容性單次執行應處理 4 次成功撮合（①1+②1+③1+④0+⑤1）');

-- 這幾組都是「雙方各自 1 人、min=2/max=2」的簡單配對，實際累積人數剛好 2，
-- 會走 commit_match 的 PENDING_CONFIRMATION 分支（不是直接建立 Activity）—
-- 跟 15_matching_engine_nway.test.sql 情境②的判準一致，見該檔案說明。

select is(
  (select count(*)::int from match_request
    where id in ((select t1_a_id from fixtures), (select t1_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '① 全形括號/前後空白正規化後相同：原文不同但應配對成功'
);

select is(
  (select count(*)::int from match_request
    where id in ((select t2_a_id from fixtures), (select t2_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '② 大小寫正規化後相同（TOEFL vs toefl）：應配對成功'
);

select is(
  (select count(*)::int from match_request
    where id in ((select t3_a_id from fixtures), (select t3_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '③ null wildcard：一方未填應可跟任何指定字串配對成功'
);

select is(
  (select count(*)::int from match_request
    where id in ((select t4_a_id from fixtures), (select t4_b_id from fixtures))
      and status = 'REQUESTING'),
  2,
  '④ 正規化後不同字串（微積分 vs 普通物理）不應配對，維持 REQUESTING'
);

select is(
  (select count(*)::int from match_request
    where id in ((select t5_a_id from fixtures), (select t5_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '⑤ 課名/考試名稱字串剛好相同（語意不同但字串一致）應配對成功，證明系統是純字串比對、不理解語意'
);

select is(
  (select study_target from match_request where id = (select t6_req_id from fixtures)),
  '  微積分（一）　',
  '⑥ study_target（原文）應完整保留使用者輸入，不做任何清理'
);

select is(
  (select study_target_normalized from match_request where id = (select t6_req_id from fixtures)),
  fn_normalize_study_target('  微積分（一）　'),
  '⑥ study_target_normalized 應為正規化後的字串（供撮合比對用）'
);

select isnt(
  (select study_target from match_request where id = (select t6_req_id from fixtures)),
  (select study_target_normalized from match_request where id = (select t6_req_id from fixtures)),
  '⑥ 同一筆 insert 後 study_target（原文）與 study_target_normalized（正規化）應確實不同，證明兩欄位分開存'
);

select * from finish();

rollback;
