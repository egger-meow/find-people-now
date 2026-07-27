-- =============================================================================
-- pgTAP Test — fn_run_matching_engine() N 方累積演算法 (v1.15)
--
-- 涵蓋三個獨立情境（各自用不同 campus 隔離，避免互相撮合）：
--   ① 時間窗兩兩重疊但整體無共同交集：A-B 重疊、B-C 重疊，但 A-C 不重疊，
--      驗證 N 方交集檢查不會誤合併（非只跟種子兩兩比較）
--   ② double-commit 回歸測試：4 個各自 1 人、min=2 的獨立陌生人，驗證單次執行
--      不會重現舊版「外層 cursor snapshot 過期，同一筆 Request 被塞進兩筆
--      pending_confirmation」的 bug
--   ③ null max_participants 下的「array_length=2 但實際人數>2」修正：候選本身
--      透過邀請連結已經是 3 人團，驗證分支判準改用實際累積人數後，會直接建立
--      Activity 而不是誤入 PENDING_CONFIRMATION
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  act_type_id   uuid,
  -- ① 無共同交集
  campus_s1     text,
  s1_a_id       uuid, s1_b_id uuid, s1_c_id uuid,
  -- ② double-commit 回歸
  campus_s2     text,
  s2_d_id       uuid, s2_e_id uuid, s2_f_id uuid, s2_g_id uuid,
  -- ③ null max 修正
  campus_s3     text,
  s3_seed_id    uuid, s3_cand_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id uuid;
  v_campus_s1   text := 'S1區';
  v_campus_s2   text := 'S2區';
  v_campus_s3   text := 'S3區';

  v_now         timestamptz := now();

  -- ① 無共同交集
  v_a_id        uuid := gen_random_uuid();
  v_b_id        uuid := gen_random_uuid();
  v_c_id        uuid := gen_random_uuid();
  v_a_req       match_request;
  v_b_req       match_request;
  v_c_req       match_request;

  -- ② double-commit
  v_d_id        uuid := gen_random_uuid();
  v_e_id        uuid := gen_random_uuid();
  v_f_id        uuid := gen_random_uuid();
  v_g_id        uuid := gen_random_uuid();
  v_d_req       match_request;
  v_e_req       match_request;
  v_f_req       match_request;
  v_g_req       match_request;

  -- ③ null max
  v_seed_id     uuid := gen_random_uuid();
  v_cand_id     uuid := gen_random_uuid();
  v_cand_f1_id  uuid := gen_random_uuid();
  v_cand_f2_id  uuid := gen_random_uuid();
  v_seed_req    match_request;
  v_cand_req    match_request;
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus_s1, 'S1測試地點', true),
    ('NYCU', v_campus_s2, 'S2測試地點', true),
    ('NYCU', v_campus_s3, 'S3測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- --------------------------------------------------------------------------
  -- ① A/B 重疊、B/C 重疊，A/C 不重疊：min=3，應該完全湊不成，全部維持 REQUESTING
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_a_id, 's1_a@nycu.edu.tw'), (v_b_id, 's1_b@nycu.edu.tw'), (v_c_id, 's1_c@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_a_id, 's1_a@nycu.edu.tw', 'NYCU', 'S1 A', 'https://avatar.s1a', 'UNDERGRAD', 's1_a_ig'),
    (v_b_id, 's1_b@nycu.edu.tw', 'NYCU', 'S1 B', 'https://avatar.s1b', 'UNDERGRAD', 's1_b_ig'),
    (v_c_id, 's1_c@nycu.edu.tw', 'NYCU', 'S1 C', 'https://avatar.s1c', 'UNDERGRAD', 's1_c_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_a_id, v_act_type_id, 'NYCU', v_campus_s1, v_now, v_now + interval '90 minutes', 3, 12, 'REQUESTING')
  returning * into v_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_a_req.id, v_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_b_id, v_act_type_id, 'NYCU', v_campus_s1, v_now + interval '60 minutes', v_now + interval '150 minutes', 3, 12, 'REQUESTING')
  returning * into v_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_b_req.id, v_b_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_c_id, v_act_type_id, 'NYCU', v_campus_s1, v_now + interval '100 minutes', v_now + interval '200 minutes', 3, 12, 'REQUESTING')
  returning * into v_c_req;
  insert into request_member (request_id, user_id, role, status) values (v_c_req.id, v_c_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ② D/E/F/G 各自 1 人、min=2/max=2，互相時間相容、無 avoidance
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_d_id, 's2_d@nycu.edu.tw'), (v_e_id, 's2_e@nycu.edu.tw'),
    (v_f_id, 's2_f@nycu.edu.tw'), (v_g_id, 's2_g@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_d_id, 's2_d@nycu.edu.tw', 'NYCU', 'S2 D', 'https://avatar.s2d', 'UNDERGRAD', 's2_d_ig'),
    (v_e_id, 's2_e@nycu.edu.tw', 'NYCU', 'S2 E', 'https://avatar.s2e', 'UNDERGRAD', 's2_e_ig'),
    (v_f_id, 's2_f@nycu.edu.tw', 'NYCU', 'S2 F', 'https://avatar.s2f', 'UNDERGRAD', 's2_f_ig'),
    (v_g_id, 's2_g@nycu.edu.tw', 'NYCU', 'S2 G', 'https://avatar.s2g', 'UNDERGRAD', 's2_g_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_d_id, v_act_type_id, 'NYCU', v_campus_s2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_d_req;
  insert into request_member (request_id, user_id, role, status) values (v_d_req.id, v_d_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_e_id, v_act_type_id, 'NYCU', v_campus_s2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_e_req;
  insert into request_member (request_id, user_id, role, status) values (v_e_req.id, v_e_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_f_id, v_act_type_id, 'NYCU', v_campus_s2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_f_req;
  insert into request_member (request_id, user_id, role, status) values (v_f_req.id, v_f_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_g_id, v_act_type_id, 'NYCU', v_campus_s2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING')
  returning * into v_g_req;
  insert into request_member (request_id, user_id, role, status) values (v_g_req.id, v_g_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ③ 種子 min=2/max=null，候選是透過邀請連結已有 3 人（owner+2 friends）的 Request，
  --    候選 min=3/max=null；種子單獨 1 人 + 候選 3 人 = 實際 4 人，
  --    驗證分支判準用實際人數而非「array_length=2」判斷，會直接建立 Activity
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_seed_id, 's3_seed@nycu.edu.tw'), (v_cand_id, 's3_cand@nycu.edu.tw'),
    (v_cand_f1_id, 's3_cand_f1@nycu.edu.tw'), (v_cand_f2_id, 's3_cand_f2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_seed_id, 's3_seed@nycu.edu.tw', 'NYCU', 'S3 Seed', 'https://avatar.s3seed', 'UNDERGRAD', 's3_seed_ig'),
    (v_cand_id, 's3_cand@nycu.edu.tw', 'NYCU', 'S3 Cand', 'https://avatar.s3cand', 'UNDERGRAD', 's3_cand_ig'),
    (v_cand_f1_id, 's3_cand_f1@nycu.edu.tw', 'NYCU', 'S3 Cand F1', 'https://avatar.s3f1', 'UNDERGRAD', 's3_f1_ig'),
    (v_cand_f2_id, 's3_cand_f2@nycu.edu.tw', 'NYCU', 'S3 Cand F2', 'https://avatar.s3f2', 'UNDERGRAD', 's3_f2_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_seed_id, v_act_type_id, 'NYCU', v_campus_s3, v_now, v_now + interval '2 hours', 2, null, 'REQUESTING')
  returning * into v_seed_req;
  insert into request_member (request_id, user_id, role, status) values (v_seed_req.id, v_seed_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_cand_id, v_act_type_id, 'NYCU', v_campus_s3, v_now, v_now + interval '2 hours', 3, null, 'REQUESTING')
  returning * into v_cand_req;
  insert into request_member (request_id, user_id, role, status) values
    (v_cand_req.id, v_cand_id, 'OWNER', 'JOINED'),
    (v_cand_req.id, v_cand_f1_id, 'MEMBER', 'JOINED'),
    (v_cand_req.id, v_cand_f2_id, 'MEMBER', 'JOINED');

  update fixtures set
    act_type_id = v_act_type_id,
    campus_s1 = v_campus_s1, s1_a_id = v_a_req.id, s1_b_id = v_b_req.id, s1_c_id = v_c_req.id,
    campus_s2 = v_campus_s2, s2_d_id = v_d_req.id, s2_e_id = v_e_req.id, s2_f_id = v_f_req.id, s2_g_id = v_g_req.id,
    campus_s3 = v_campus_s3, s3_seed_id = v_seed_req.id, s3_cand_id = v_cand_req.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 執行一次 Matching Engine，同時處理三個情境
-- 預期：① 0 次成局；② 2 次（D-E、F-G 各一組 pending_confirmation）；
--       ③ 1 次（直接建立 Activity）→ 合計 3
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 3, 'N 方累積演算法單次執行應處理 3 個情境（①0 + ②2 + ③1）');

-- -----------------------------------------------------------------------------
-- ① 驗證：A/B/C 三筆全部維持 REQUESTING（沒有任何共同交集，不應被合併）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_request
    where id in ((select s1_a_id from fixtures), (select s1_b_id from fixtures), (select s1_c_id from fixtures))
      and status = 'REQUESTING'),
  3,
  'A-B 重疊、B-C 重疊但 A-C 無共同交集：三筆應全部維持 REQUESTING，不應被誤合併'
);

-- -----------------------------------------------------------------------------
-- ② double-commit 回歸驗證
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from pending_confirmation
    where request_a_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
       or request_b_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))),
  2,
  'D/E/F/G 四個獨立陌生人應恰好產生 2 筆 pending_confirmation'
);

select is(
  (select count(*)::int from (
    select rid from (
      select request_a_id as rid from pending_confirmation
       where request_a_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
          or request_b_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
       union all
      select request_b_id from pending_confirmation
       where request_a_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
          or request_b_id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
    ) all_rids
    group by rid having count(*) > 1
  ) dup),
  0,
  '（回歸測試）沒有任何一筆 Request 同時出現在兩筆 pending_confirmation——修正舊版外層 cursor snapshot 過期導致的 double-commit bug'
);

select is(
  (select count(*)::int from match_request
    where id in ((select s2_d_id from fixtures), (select s2_e_id from fixtures), (select s2_f_id from fixtures), (select s2_g_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  4,
  'D/E/F/G 四筆都應轉為 PENDING_CONFIRMATION（各自剛好在一組裡）'
);

-- -----------------------------------------------------------------------------
-- ③ null max_participants 修正驗證：應直接建立 Activity，不是 PENDING_CONFIRMATION
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select s3_seed_id from fixtures)),
  'MATCHED',
  '種子 min=2 但實際累積人數(4)>2：應直接建立 Activity，不應誤入 PENDING_CONFIRMATION'
);

select is(
  (select count(*)::int from pending_confirmation
    where request_a_id in ((select s3_seed_id from fixtures), (select s3_cand_id from fixtures))
       or request_b_id in ((select s3_seed_id from fixtures), (select s3_cand_id from fixtures))),
  0,
  '情境③不應產生任何 pending_confirmation 記錄'
);

select is(
  (select count(*)::int from activity_member am
    join activity a on a.id = am.activity_id
   where a.school = 'NYCU' and a.campus = (select campus_s3 from fixtures) and a.status = 'MATCHED'),
  4,
  '情境③建立的 Activity 應包含全部 4 人（種子 1 人 + 候選自己的 3 人團）'
);

select * from finish();

rollback;
