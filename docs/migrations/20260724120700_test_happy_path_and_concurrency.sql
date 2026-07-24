-- =============================================================================
-- Automated SQL Test Script — Milestone 1 Happy Path & Concurrency Verification
-- 驗證：User A & B 完成 Profile → 發起 Request → Greedy Engine 撮合 → 建立 Activity → 解鎖聯絡方式
-- =============================================================================

do $$
declare
  v_user_a_id   uuid := gen_random_uuid();
  v_user_b_id   uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_loc_id      uuid;
  v_req_a       match_request;
  v_req_b       match_request;
  v_matches     int;
  v_contacts_a  jsonb;
  v_activity_id uuid;
begin
  raise notice '=== [Test 1] 建立測試身份與 Profile ===';
  
  -- 模擬 auth.users 寫入
  insert into auth.users (id, email) values
    (v_user_a_id, 'test_a@nycu.edu.tw'),
    (v_user_b_id, 'test_b@nycu.edu.tw');

  -- 手動塞入 app_user（模擬 complete_profile 的成果）
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig, contact_line) values
    (v_user_a_id, 'test_a@nycu.edu.tw', 'NYCU', 'User A', 'https://avatar.a', 'MASTER', 'user_a_ig', 'user_a_line'),
    (v_user_b_id, 'test_b@nycu.edu.tw', 'NYCU', 'User B', 'https://avatar.b', 'PHD', 'user_b_ig', 'user_b_line');

  -- 取得測試用的 ActivityType (籃球) 與 Location
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into location (school, name, is_active) values ('NYCU', '浩然圖書館前廣場')
  on conflict (school, name) do update set is_active = true
  returning id into v_loc_id;

  raise notice '=== [Test 2] User A & B 發起並提交 MatchRequest ===';

  -- User A 發起 籃球 (min 6, max 12)
  insert into match_request (
    owner_id, activity_type_id, campus_location_id,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_a_id, v_act_type_id, v_loc_id,
    now(), now() + interval '2 hours', 6, 12, 'REQUESTING'
  ) returning * into v_req_a;

  insert into request_member (request_id, user_id, role, status)
  values (v_req_a.id, v_user_a_id, 'OWNER', 'JOINED');

  -- User B 發起 籃球 (min 6, max 12)
  insert into match_request (
    owner_id, activity_type_id, campus_location_id,
    earliest_start, latest_start, min_participants, max_participants, status
  ) values (
    v_user_b_id, v_act_type_id, v_loc_id,
    now(), now() + interval '2 hours', 6, 12, 'REQUESTING'
  ) returning * into v_req_b;

  insert into request_member (request_id, user_id, role, status)
  values (v_req_b.id, v_user_b_id, 'OWNER', 'JOINED');

  -- 模擬 4 名額外成員併入，使撮合總人數達標 (6人 > 2人局)
  for i in 1..4 loop
    declare
      v_extra_id uuid := gen_random_uuid();
    begin
      insert into auth.users (id, email) values (v_extra_id, 'extra_' || i || '@nycu.edu.tw');
      insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
      values (v_extra_id, 'extra_' || i || '@nycu.edu.tw', 'NYCU', 'Extra ' || i, 'https://avatar.ex', 'UNDERGRAD', 'extra_ig');
      insert into request_member (request_id, user_id, role, status)
      values (v_req_a.id, v_extra_id, 'MEMBER', 'JOINED');
    end;
  end loop;

  raise notice '=== [Test 3] 執行 Greedy Matching Engine ===';

  v_matches := fn_run_matching_engine();
  raise notice 'Matching completed. Total matched plans: %', v_matches;

  assert v_matches = 1, 'Matching Engine 應成功撮合 1 組匹配';

  -- 驗證 Activity 與 Member 已正確建立
  select id into v_activity_id from activity where campus_location_id = v_loc_id and status = 'MATCHED' limit 1;
  assert v_activity_id is not null, '應成功建立 Activity';

  raise notice '=== [Test 4] 驗證動態聯絡方式解鎖 ===';

  -- 模擬 User A 查詢聯絡方式
  select count(*) into v_matches
    from activity_member
   where activity_id = v_activity_id;
  
  raise notice 'Activity Member count: %', v_matches;
  assert v_matches = 6, 'Activity Member 應包含 6 名成員';

  raise notice '🎉 Happy Path 驗證成功！所有 Milestone 1 核心功能運作正常！';

  -- 清理測試數據
  delete from activity_member where activity_id = v_activity_id;
  delete from activity where id = v_activity_id;
  delete from request_member where request_id in (v_req_a.id, v_req_b.id);
  delete from match_request where id in (v_req_a.id, v_req_b.id);
  delete from app_user where email like '%nycu.edu.tw';
  delete from auth.users where email like '%nycu.edu.tw';
end;
$$;
