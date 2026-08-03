-- =============================================================================
-- pgTAP Test — complete_profile 硬性門檻 + get_activity_member_profiles.bio (v1.33)
-- =============================================================================
-- 起因：使用者要求 bio（自我介紹）從選填改成註冊硬性門檻，且擋掉 Dicebear
-- 自動產生的佔位頭像（見 20260803150000_bio_avatar_hard_requirements.sql）；
-- 同時 get_activity_member_profiles 新增回傳 bio 供「個人檔案卡」使用（見
-- 20260803150100_activity_member_profiles_bio.sql）。
--
-- 順便補上 complete_profile 既有的硬性門檻（DISPLAY_NAME_REQUIRED/
-- AVATAR_URL_REQUIRED/NO_CONTACT_METHOD）從未有過的 pgTAP 覆蓋——盤點時確認
-- 這支 RPC 的必填驗證分支完全沒有任何測試（唯一提到 complete_profile 的
-- 31_default_campus.test.sql 只測 p_default_campus 的 coalesce 行為，每次呼叫
-- 都已經帶了合法的必填欄位）。
--
-- 每個必填檢查在 complete_profile 內是有順序的（依序：DISPLAY_NAME_REQUIRED
-- → AVATAR_URL_REQUIRED → PLACEHOLDER_AVATAR_NOT_ALLOWED → BIO_REQUIRED →
-- DEGREE_LEVEL_REQUIRED → NO_CONTACT_METHOD），所以每個測試案例都把「這個
-- 檢查之前」的欄位填成合法值，只留下要測的那個欄位觸發失敗，才能真正測到
-- 目標分支而不是被更早的檢查攔截。
--
-- pgTAP 的 throws_matching 只比對例外的 MESSAGE，不比對 DETAIL，而
-- complete_profile 底下好幾個門檻共用同一個 MESSAGE（'PROFILE_INCOMPLETE'），
-- 沒辦法只靠 throws_matching 分辨是哪一個門檻擋下的——這裡改用
-- GET STACKED DIAGNOSTICS 抓 PG_EXCEPTION_DETAIL，存進 fixtures 暫存表，再用
-- 頂層 select is(...) 斷言，維持 pgTAP TAP 輸出的既有寫法（is()/ok() 的回傳值
-- 要是頂層 select 才會被收進 TAP 輸出，plpgsql 區塊裡 perform 會把回傳值丟掉）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(8);

-- -----------------------------------------------------------------------------
-- 0. Setup — 一個尚未完成 profile 的 NYCU 使用者，加上供
--    get_activity_member_profiles 測試用的一組已配對活動。
-- -----------------------------------------------------------------------------

create temp table fixtures (
  user_id            uuid,
  detail_scratch     text,
  member_a_id        uuid,
  member_b_id        uuid,
  activity_id        uuid
);
insert into fixtures default values;

do $setup$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_id, 'phr_user@nycu.edu.tw');
  update fixtures set user_id = v_id;
end;
$setup$;

grant select, update on fixtures to authenticated;

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select user_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. DISPLAY_NAME_REQUIRED — 空白顯示名稱。
-- -----------------------------------------------------------------------------

do $$
declare
  v_detail text;
begin
  begin
    perform complete_profile(
      p_display_name := '',
      p_avatar_url    := 'https://avatar.phr_user',
      p_degree_level  := 'UNDERGRAD',
      p_bio           := 'Hi there',
      p_contact_line  := 'phr_user_line'
    );
    v_detail := null;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  update fixtures set detail_scratch = v_detail;
end $$;

select is(
  (select detail_scratch from fixtures),
  'DISPLAY_NAME_REQUIRED',
  '空白顯示名稱應回 PROFILE_INCOMPLETE / DISPLAY_NAME_REQUIRED'
);

-- -----------------------------------------------------------------------------
-- 2. AVATAR_URL_REQUIRED — 空白頭像網址。
-- -----------------------------------------------------------------------------

do $$
declare
  v_detail text;
begin
  begin
    perform complete_profile(
      p_display_name := 'PHR User',
      p_avatar_url    := '',
      p_degree_level  := 'UNDERGRAD',
      p_bio           := 'Hi there',
      p_contact_line  := 'phr_user_line'
    );
    v_detail := null;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  update fixtures set detail_scratch = v_detail;
end $$;

select is(
  (select detail_scratch from fixtures),
  'AVATAR_URL_REQUIRED',
  '空白頭像網址應回 PROFILE_INCOMPLETE / AVATAR_URL_REQUIRED'
);

-- -----------------------------------------------------------------------------
-- 3. PLACEHOLDER_AVATAR_NOT_ALLOWED — Dicebear 自動產生的佔位頭像（v1.33）。
-- -----------------------------------------------------------------------------

do $$
declare
  v_detail text;
begin
  begin
    perform complete_profile(
      p_display_name := 'PHR User',
      p_avatar_url    := 'https://api.dicebear.com/9.x/thumbs/png?seed=phr-user',
      p_degree_level  := 'UNDERGRAD',
      p_bio           := 'Hi there',
      p_contact_line  := 'phr_user_line'
    );
    v_detail := null;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  update fixtures set detail_scratch = v_detail;
end $$;

select is(
  (select detail_scratch from fixtures),
  'PLACEHOLDER_AVATAR_NOT_ALLOWED',
  'Dicebear 佔位頭像應回 PROFILE_INCOMPLETE / PLACEHOLDER_AVATAR_NOT_ALLOWED'
);

-- -----------------------------------------------------------------------------
-- 4. BIO_REQUIRED — 空白/未帶自我介紹（v1.33）。
-- -----------------------------------------------------------------------------

do $$
declare
  v_detail text;
begin
  begin
    perform complete_profile(
      p_display_name := 'PHR User',
      p_avatar_url    := 'https://avatar.phr_user',
      p_degree_level  := 'UNDERGRAD',
      p_contact_line  := 'phr_user_line'
      -- p_bio 未帶，走 default null
    );
    v_detail := null;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  update fixtures set detail_scratch = v_detail;
end $$;

select is(
  (select detail_scratch from fixtures),
  'BIO_REQUIRED',
  '空白自我介紹應回 PROFILE_INCOMPLETE / BIO_REQUIRED'
);

-- -----------------------------------------------------------------------------
-- 5. DEGREE_LEVEL_REQUIRED — 未帶學制。
-- -----------------------------------------------------------------------------

-- DEGREE_LEVEL_REQUIRED 這個 raise 沒有帶 detail（訊息本體就是代碼），所以
-- 這裡改抓 SQLERRM（訊息本體），不是 pg_exception_detail——避免「沒帶
-- detail 的合法拋出」跟「根本沒拋出例外」在 detail 欄位上長得一樣（都是
-- null），讓斷言測不出退化成沒驗證的情況。
do $$
declare
  v_message text;
begin
  begin
    perform complete_profile(
      p_display_name := 'PHR User',
      p_avatar_url    := 'https://avatar.phr_user',
      p_degree_level  := null,
      p_bio           := 'Hi there',
      p_contact_line  := 'phr_user_line'
    );
    v_message := 'NO_EXCEPTION_RAISED';
  exception when others then
    v_message := SQLERRM;
  end;
  update fixtures set detail_scratch = v_message;
end $$;

select is(
  (select detail_scratch from fixtures),
  'DEGREE_LEVEL_REQUIRED',
  '未帶學制應拋出 DEGREE_LEVEL_REQUIRED'
);

-- -----------------------------------------------------------------------------
-- 6. NO_CONTACT_METHOD — 三個聯絡方式都沒填。
-- -----------------------------------------------------------------------------

do $$
declare
  v_detail text;
begin
  begin
    perform complete_profile(
      p_display_name := 'PHR User',
      p_avatar_url    := 'https://avatar.phr_user',
      p_degree_level  := 'UNDERGRAD',
      p_bio           := 'Hi there'
    );
    v_detail := null;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  update fixtures set detail_scratch = v_detail;
end $$;

select is(
  (select detail_scratch from fixtures),
  'AT_LEAST_ONE_CONTACT_REQUIRED',
  '三個聯絡方式都沒填應回 NO_CONTACT_METHOD / AT_LEAST_ONE_CONTACT_REQUIRED'
);

-- -----------------------------------------------------------------------------
-- 7. 成功案例 — 合法 bio + 非 Dicebear 頭像應正常寫入。
-- -----------------------------------------------------------------------------

select complete_profile(
  p_display_name := 'PHR User',
  p_avatar_url    := 'https://avatar.phr_user/real.jpg',
  p_degree_level  := 'UNDERGRAD',
  p_bio           := '研究所碩一，平常喜歡打球、看電影',
  p_contact_line  := 'phr_user_line'
);

select is(
  (select bio from app_user where id = (select user_id from fixtures)),
  '研究所碩一，平常喜歡打球、看電影',
  '合法 bio + 非 Dicebear 頭像應成功寫入 app_user.bio'
);

reset role;

-- -----------------------------------------------------------------------------
-- 8. get_activity_member_profiles 應回傳 bio（v1.33 新增欄位）。
-- -----------------------------------------------------------------------------

do $setup2$
declare
  v_act_type_id uuid;
  v_campus      text := 'PHR測試區';
  v_now         timestamptz := now();
  v_a           uuid := (select user_id from fixtures);
  v_b           uuid := gen_random_uuid();
  v_req         match_request;
  v_activity    activity;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into auth.users (id, email) values (v_b, 'phr_b@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, bio, contact_line) values
    (v_b, 'phr_b@nycu.edu.tw', 'NYCU', 'PHR Member B', 'https://avatar.phr_b', 'MASTER', '喜歡爬山', 'phr_b_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_a, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 4, 'MATCHED')
  returning * into v_req;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, v_now + interval '1 hour', v_now + interval '2 hours', 'MATCHED')
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status) values
    (v_activity.id, v_a, v_req.id, 'JOINED'),
    (v_activity.id, v_b, v_req.id, 'JOINED');

  update fixtures set member_a_id = v_a, member_b_id = v_b, activity_id = v_activity.id;
end;
$setup2$;

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member_a_id::text from fixtures), true);
end $$;

select is(
  (
    select elem->>'bio'
    from jsonb_array_elements(get_activity_member_profiles((select activity_id from fixtures))) elem
    where elem->>'user_id' = (select member_b_id::text from fixtures)
  ),
  '喜歡爬山',
  'get_activity_member_profiles 應回傳成員的 bio（個人檔案卡用）'
);

reset role;

select * from finish();

rollback;
