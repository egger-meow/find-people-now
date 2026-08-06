-- =============================================================================
-- pgTAP Test — Skill Level 撮合相容性 (v1.34)
-- =============================================================================
-- 涵蓋（各自用不同 campus 隔離，避免互相撮合）：
--   ① wildcard 相容：一方 skill_level = null，應可跟任何指定等級配對
--   ② 同級相容：兩邊都是 ADVANCED，應可配對
--   ③ 不同級不相容：ADVANCED vs COMPETITIVE，應維持 REQUESTING，不應被合併
--   ④ flag 關閉時完全不受影響：對 skill_level_enabled=false 的類型（咖啡）呼叫
--      create_request 並帶 p_skill_level，驗證實際寫入的欄位值被強制設為 null
--      （寫入時強制，不是報錯——見 20260803160100_skill_level_rpc.sql 說明）
--   ⑤ 可擴充性：模擬一個全新的、skill_level_enabled=true 的競技類型「排球」
--      （測試檔內臨時建立，不動任何官方 seed），驗證不改任何 matching engine
--      程式碼就能正確撮合／擋掉——直接驗證「未來新競技類型能不能掛上」這個
--      需求本身，不是驗證既有的籃球/羽球。
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
  basketball_type_id  uuid,
  badminton_type_id   uuid,
  coffee_type_id      uuid,
  volleyball_type_id  uuid,
  -- ①②③
  campus_sk1          text,
  sk1_a_id            uuid, sk1_b_id uuid,
  campus_sk2          text,
  sk2_a_id            uuid, sk2_b_id uuid,
  campus_sk3          text,
  sk3_a_id            uuid, sk3_b_id uuid,
  -- ④
  campus_sk4          text,
  sk4_user_id         uuid,
  sk4_req_id          uuid,
  -- ⑤
  campus_sk5a         text,
  sk5a_user1_id       uuid, sk5a_user2_id uuid,
  sk5a_req1_id         uuid, sk5a_req2_id uuid,
  campus_sk5b         text,
  sk5b_user1_id       uuid, sk5b_user2_id uuid,
  sk5b_req1_id         uuid, sk5b_req2_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_basketball_id uuid;
  v_badminton_id  uuid;
  v_coffee_id     uuid;
  v_volleyball_id uuid := gen_random_uuid();

  v_campus_sk1 text := 'SK1區';
  v_campus_sk2 text := 'SK2區';
  v_campus_sk3 text := 'SK3區';
  v_campus_sk4 text := 'SK4區';
  v_campus_sk5a text := 'SK5A區';
  v_campus_sk5b text := 'SK5B區';

  v_now timestamptz := now();

  v_sk1_a_id uuid := gen_random_uuid();
  v_sk1_b_id uuid := gen_random_uuid();
  v_sk1_a_req match_request;
  v_sk1_b_req match_request;

  v_sk2_a_id uuid := gen_random_uuid();
  v_sk2_b_id uuid := gen_random_uuid();
  v_sk2_a_req match_request;
  v_sk2_b_req match_request;

  v_sk3_a_id uuid := gen_random_uuid();
  v_sk3_b_id uuid := gen_random_uuid();
  v_sk3_a_req match_request;
  v_sk3_b_req match_request;

  v_sk4_user_id uuid := gen_random_uuid();
begin
  select id into v_basketball_id from activity_type where name = '籃球' limit 1;
  select id into v_badminton_id from activity_type where name = '羽球' limit 1;
  select id into v_coffee_id from activity_type where name = '吃飯/咖啡/探店' limit 1;

  -- ⑤：模擬一個全新、skill_level_enabled=true 的競技類型「排球」——不動任何
  -- 官方 seed，只在這個測試 transaction 內臨時建立，測試結束自動 rollback。
  insert into activity_type (
    id, name, status, default_duration_minutes,
    default_min_participants, default_max_participants, group_size_step,
    skill_level_enabled
  ) values (
    v_volleyball_id, '排球', 'APPROVED', 90, 2, 4, null, true
  );

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus_sk1, 'SK1測試地點', true),
    ('NYCU', v_campus_sk2, 'SK2測試地點', true),
    ('NYCU', v_campus_sk3, 'SK3測試地點', true),
    ('NYCU', v_campus_sk4, 'SK4測試地點', true),
    ('NYCU', v_campus_sk5a, 'SK5A測試地點', true),
    ('NYCU', v_campus_sk5b, 'SK5B測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- --------------------------------------------------------------------------
  -- ① wildcard：A 不限、B 進階 → 應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_sk1_a_id, 'sk1_a@nycu.edu.tw'), (v_sk1_b_id, 'sk1_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_sk1_a_id, 'sk1_a@nycu.edu.tw', 'NYCU', 'SK1 A', 'https://avatar.sk1a', 'UNDERGRAD', 'sk1_a_ig'),
    (v_sk1_b_id, 'sk1_b@nycu.edu.tw', 'NYCU', 'SK1 B', 'https://avatar.sk1b', 'UNDERGRAD', 'sk1_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk1_a_id, v_basketball_id, 'NYCU', v_campus_sk1, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', null)
  returning * into v_sk1_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk1_a_req.id, v_sk1_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk1_b_id, v_basketball_id, 'NYCU', v_campus_sk1, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', 'ADVANCED')
  returning * into v_sk1_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk1_b_req.id, v_sk1_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ② 同級相容：A/B 都是 ADVANCED → 應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_sk2_a_id, 'sk2_a@nycu.edu.tw'), (v_sk2_b_id, 'sk2_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_sk2_a_id, 'sk2_a@nycu.edu.tw', 'NYCU', 'SK2 A', 'https://avatar.sk2a', 'UNDERGRAD', 'sk2_a_ig'),
    (v_sk2_b_id, 'sk2_b@nycu.edu.tw', 'NYCU', 'SK2 B', 'https://avatar.sk2b', 'UNDERGRAD', 'sk2_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk2_a_id, v_badminton_id, 'NYCU', v_campus_sk2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', 'ADVANCED')
  returning * into v_sk2_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk2_a_req.id, v_sk2_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk2_b_id, v_badminton_id, 'NYCU', v_campus_sk2, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', 'ADVANCED')
  returning * into v_sk2_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk2_b_req.id, v_sk2_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ③ 不同級不相容：A=ADVANCED、B=COMPETITIVE → 不應配對
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (v_sk3_a_id, 'sk3_a@nycu.edu.tw'), (v_sk3_b_id, 'sk3_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_sk3_a_id, 'sk3_a@nycu.edu.tw', 'NYCU', 'SK3 A', 'https://avatar.sk3a', 'UNDERGRAD', 'sk3_a_ig'),
    (v_sk3_b_id, 'sk3_b@nycu.edu.tw', 'NYCU', 'SK3 B', 'https://avatar.sk3b', 'UNDERGRAD', 'sk3_b_ig');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk3_a_id, v_badminton_id, 'NYCU', v_campus_sk3, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', 'ADVANCED')
  returning * into v_sk3_a_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk3_a_req.id, v_sk3_a_id, 'OWNER', 'JOINED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, skill_level)
  values (v_sk3_b_id, v_badminton_id, 'NYCU', v_campus_sk3, v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING', 'COMPETITIVE')
  returning * into v_sk3_b_req;
  insert into request_member (request_id, user_id, role, status) values (v_sk3_b_req.id, v_sk3_b_id, 'OWNER', 'JOINED');

  -- --------------------------------------------------------------------------
  -- ④ flag 關閉：咖啡（skill_level_enabled=false）使用者，之後透過 create_request
  --    帶 p_skill_level 驗證
  -- --------------------------------------------------------------------------
  insert into auth.users (id, email) values (v_sk4_user_id, 'sk4_user@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_sk4_user_id, 'sk4_user@nycu.edu.tw', 'NYCU', 'SK4 User', 'https://avatar.sk4', 'UNDERGRAD', 'sk4_ig');

  update fixtures set
    basketball_type_id = v_basketball_id, badminton_type_id = v_badminton_id,
    coffee_type_id = v_coffee_id, volleyball_type_id = v_volleyball_id,
    campus_sk1 = v_campus_sk1, sk1_a_id = v_sk1_a_req.id, sk1_b_id = v_sk1_b_req.id,
    campus_sk2 = v_campus_sk2, sk2_a_id = v_sk2_a_req.id, sk2_b_id = v_sk2_b_req.id,
    campus_sk3 = v_campus_sk3, sk3_a_id = v_sk3_a_req.id, sk3_b_id = v_sk3_b_req.id,
    campus_sk4 = v_campus_sk4, sk4_user_id = v_sk4_user_id,
    campus_sk5a = v_campus_sk5a, campus_sk5b = v_campus_sk5b;
end;
$setup$;

grant select, update on fixtures to authenticated;

-- -----------------------------------------------------------------------------
-- ④ 呼叫 create_request（咖啡，skill_level_enabled=false）並帶 p_skill_level，
--    驗證寫入的 skill_level 一律是 null（靜默忽略，不報錯）
-- -----------------------------------------------------------------------------

-- ⑤ 全新類型「排球」端到端測試用的使用者：跟 fixtures 一樣，必須在切換到
-- authenticated role 之前，用 superuser 身分建立（auth.users 沒有開放
-- authenticated 角色 INSERT 權限）。
--
-- submit_request 對 min_participants<=2 的「新人」有低人數門檻擋 (SPEC §12.1
-- NEW_USER_LOW_HEADCOUNT，見 20260724120300_rpc_match_request.sql)——
-- fn_is_new_user 判準是「從未有過 ATTENDED 事件」，剛建立的測試使用者一律算
-- 新人。這幾組是要測 skill_level 相容性，不是要測這個門檻，所以先塞一筆
-- ATTENDED 事件讓這 4 個使用者不被判定為新人。
do $$
declare
  v_sk5a_1 uuid := gen_random_uuid();
  v_sk5a_2 uuid := gen_random_uuid();
  v_sk5b_1 uuid := gen_random_uuid();
  v_sk5b_2 uuid := gen_random_uuid();
  v_dummy_act_type_id uuid;
  v_dummy_activity     activity;
begin
  insert into auth.users (id, email) values
    (v_sk5a_1, 'sk5a_1@nycu.edu.tw'), (v_sk5a_2, 'sk5a_2@nycu.edu.tw'),
    (v_sk5b_1, 'sk5b_1@nycu.edu.tw'), (v_sk5b_2, 'sk5b_2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig) values
    (v_sk5a_1, 'sk5a_1@nycu.edu.tw', 'NYCU', 'SK5A 1', 'https://avatar.sk5a1', 'UNDERGRAD', 'sk5a1_ig'),
    (v_sk5a_2, 'sk5a_2@nycu.edu.tw', 'NYCU', 'SK5A 2', 'https://avatar.sk5a2', 'UNDERGRAD', 'sk5a2_ig'),
    (v_sk5b_1, 'sk5b_1@nycu.edu.tw', 'NYCU', 'SK5B 1', 'https://avatar.sk5b1', 'UNDERGRAD', 'sk5b1_ig'),
    (v_sk5b_2, 'sk5b_2@nycu.edu.tw', 'NYCU', 'SK5B 2', 'https://avatar.sk5b2', 'UNDERGRAD', 'sk5b2_ig');

  select id into v_dummy_act_type_id from activity_type where name = '籃球' limit 1;
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_dummy_act_type_id, 'NYCU', 'SK5假活動地點', now() - interval '2 days', now() - interval '1 day', 'COMPLETED')
  returning * into v_dummy_activity;

  insert into user_reliability_event (user_id, activity_id, event_type) values
    (v_sk5a_1, v_dummy_activity.id, 'ATTENDED'),
    (v_sk5a_2, v_dummy_activity.id, 'ATTENDED'),
    (v_sk5b_1, v_dummy_activity.id, 'ATTENDED'),
    (v_sk5b_2, v_dummy_activity.id, 'ATTENDED');

  update fixtures set
    sk5a_user1_id = v_sk5a_1, sk5a_user2_id = v_sk5a_2,
    sk5b_user1_id = v_sk5b_1, sk5b_user2_id = v_sk5b_2;
end $$;

set local role authenticated;

do $$
declare
  v_req match_request;
begin
  perform set_config('request.jwt.claim.sub', (select sk4_user_id::text from fixtures), true);
  v_req := create_request(
    p_activity_type_id := (select coffee_type_id from fixtures),
    p_campus            := (select campus_sk4 from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 4,
    p_allow_downgrade        := false,
    p_skill_level             := 'ADVANCED'
  );
  update fixtures set sk4_req_id = v_req.id;
end $$;

-- --------------------------------------------------------------------------
-- ⑤ 全新類型「排球」端到端：走 create_request → submit_request，不直接寫表，
--    驗證整條 pipeline（RPC + engine）對新類型免改碼即可運作。
-- --------------------------------------------------------------------------

do $$
declare
  v_req1 match_request;
  v_req2 match_request;
begin
  perform set_config('request.jwt.claim.sub', (select sk5a_user1_id::text from fixtures), true);
  v_req1 := create_request(
    p_activity_type_id := (select volleyball_type_id from fixtures),
    p_campus            := (select campus_sk5a from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 2,
    p_allow_downgrade        := false,
    p_skill_level             := 'BEGINNER'
  );
  perform submit_request(v_req1.id);

  perform set_config('request.jwt.claim.sub', (select sk5a_user2_id::text from fixtures), true);
  v_req2 := create_request(
    p_activity_type_id := (select volleyball_type_id from fixtures),
    p_campus            := (select campus_sk5a from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 2,
    p_allow_downgrade        := false,
    p_skill_level             := 'BEGINNER'
  );
  perform submit_request(v_req2.id);

  update fixtures set sk5a_req1_id = v_req1.id, sk5a_req2_id = v_req2.id;
end $$;

do $$
declare
  v_req1 match_request;
  v_req2 match_request;
begin
  perform set_config('request.jwt.claim.sub', (select sk5b_user1_id::text from fixtures), true);
  v_req1 := create_request(
    p_activity_type_id := (select volleyball_type_id from fixtures),
    p_campus            := (select campus_sk5b from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 2,
    p_allow_downgrade        := false,
    p_skill_level             := 'BEGINNER'
  );
  perform submit_request(v_req1.id);

  perform set_config('request.jwt.claim.sub', (select sk5b_user2_id::text from fixtures), true);
  v_req2 := create_request(
    p_activity_type_id := (select volleyball_type_id from fixtures),
    p_campus            := (select campus_sk5b from fixtures),
    p_earliest_start     := now(),
    p_latest_start        := now() + interval '2 hours',
    p_min_participants     := 2,
    p_max_participants      := 2,
    p_allow_downgrade        := false,
    p_skill_level             := 'COMPETITIVE'
  );
  perform submit_request(v_req2.id);

  update fixtures set sk5b_req1_id = v_req1.id, sk5b_req2_id = v_req2.id;
end $$;

reset role;

-- -----------------------------------------------------------------------------
-- 執行一次 Matching Engine，同時處理 ①②③⑤a⑤b
-- 預期：①1（wildcard 配對）+②1（同級配對）+③0（不同級不配對）
--       +⑤a 1（排球同級配對）+⑤b 0（排球不同級不配對）＝ 3
-- -----------------------------------------------------------------------------

select is(fn_run_matching_engine(), 3, 'Skill Level 相容性單次執行應處理 3 次成功撮合（①1+②1+③0+⑤a1+⑤b0）');

-- 這幾組都是「雙方各自 1 人、min=2/max=2」的簡單配對，實際累積人數剛好 2，
-- 會走 commit_match 的 PENDING_CONFIRMATION 分支（不是直接建立 Activity）—
-- 跟 15_matching_engine_nway.test.sql 情境②的判準一致，見該檔案說明。

select is(
  (select count(*)::int from match_request
    where id in ((select sk1_a_id from fixtures), (select sk1_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '① wildcard（一方 null）應可跟任何指定等級配對成功'
);

select is(
  (select count(*)::int from match_request
    where id in ((select sk2_a_id from fixtures), (select sk2_b_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '② 同級（都是 ADVANCED）應配對成功'
);

select is(
  (select count(*)::int from match_request
    where id in ((select sk3_a_id from fixtures), (select sk3_b_id from fixtures))
      and status = 'REQUESTING'),
  2,
  '③ 不同級（ADVANCED vs COMPETITIVE）不應配對，維持 REQUESTING'
);

select is(
  (select skill_level::text from match_request where id = (select sk4_req_id from fixtures)),
  null::text,
  '④ skill_level_enabled=false 的類型（咖啡）呼叫 create_request 帶 p_skill_level，實際寫入值應被強制為 null'
);

select is(
  (select count(*)::int from match_request
    where id in ((select sk5a_req1_id from fixtures), (select sk5a_req2_id from fixtures))
      and status = 'PENDING_CONFIRMATION'),
  2,
  '⑤a 全新類型「排球」（測試臨時建立，skill_level_enabled=true）：同級應配對成功，證明機制對新類型免改碼即可運作'
);

select is(
  (select count(*)::int from match_request
    where id in ((select sk5b_req1_id from fixtures), (select sk5b_req2_id from fixtures))
      and status = 'REQUESTING'),
  2,
  '⑤b 全新類型「排球」：不同級不應配對，維持 REQUESTING'
);

select * from finish();

rollback;
