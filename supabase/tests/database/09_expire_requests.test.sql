-- =============================================================================
-- pgTAP Test — fn_expire_requests() (docs/API.md §9「Request 過期」，首次實作)
--
-- 涵蓋設計文件裡列出的每條分支：
--   ① 直接 EXPIRED（allow_downgrade=false）
--   ② 建立 downgrade_request（allow_downgrade=true，target_size 有效，剛過期不久）
--   ③ 已經超過寬限期太久才被掃到 → 直接 EXPIRED，不再提供 downgrade
--   ④ 曾經問過一次 downgrade 但被 REJECTED → 不再問第二次，直接 EXPIRED
--   ⑤ 自給自足邊緣情況（實際人數已達 min_participants）→ 不動它
--   ⑥ target_size 算法：greatest(2, 實際 JOINED 人數)
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(11);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  act_type_id  uuid,
  campus       text,
  -- req1: allow_downgrade=false，min=4，只有 1 人 → 直接 EXPIRED
  req1_id      uuid, user1_id uuid,
  -- req2: allow_downgrade=true，min=5，2 人，latest_start 剛過期 1 分鐘 → 提供 downgrade
  req2_id      uuid, user2a_id uuid, user2b_id uuid,
  -- req3: allow_downgrade=true，min=5，1 人，latest_start 已過期 20 分鐘（超過 10 分鐘
  --       寬限期）→ 直接 EXPIRED，不提供 downgrade
  req3_id      uuid, user3_id uuid,
  -- req4: 已經有一筆 REJECTED 的 downgrade_request → 不再問第二次，直接 EXPIRED
  req4_id      uuid, user4_id uuid, dg4_id uuid,
  -- req5: 實際人數已經 >= min_participants（自給自足邊緣情況）→ 不動它
  req5_id      uuid, user5a_id uuid, user5b_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_user1  uuid := gen_random_uuid();
  v_user2a uuid := gen_random_uuid();
  v_user2b uuid := gen_random_uuid();
  v_user3  uuid := gen_random_uuid();
  v_user4  uuid := gen_random_uuid();
  v_user5a uuid := gen_random_uuid();
  v_user5b uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_req1 match_request;
  v_req2 match_request;
  v_req3 match_request;
  v_req4 match_request;
  v_req5 match_request;
  v_dg4  uuid;
begin
  insert into auth.users (id, email) values
    (v_user1, 'er_1@nycu.edu.tw'), (v_user2a, 'er_2a@nycu.edu.tw'), (v_user2b, 'er_2b@nycu.edu.tw'),
    (v_user3, 'er_3@nycu.edu.tw'), (v_user4, 'er_4@nycu.edu.tw'),
    (v_user5a, 'er_5a@nycu.edu.tw'), (v_user5b, 'er_5b@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_user1, 'er_1@nycu.edu.tw', 'NYCU', 'Er 1', 'https://avatar.er_1', 'MASTER', 'er_1_line'),
    (v_user2a, 'er_2a@nycu.edu.tw', 'NYCU', 'Er 2a', 'https://avatar.er_2a', 'MASTER', 'er_2a_line'),
    (v_user2b, 'er_2b@nycu.edu.tw', 'NYCU', 'Er 2b', 'https://avatar.er_2b', 'MASTER', 'er_2b_line'),
    (v_user3, 'er_3@nycu.edu.tw', 'NYCU', 'Er 3', 'https://avatar.er_3', 'MASTER', 'er_3_line'),
    (v_user4, 'er_4@nycu.edu.tw', 'NYCU', 'Er 4', 'https://avatar.er_4', 'MASTER', 'er_4_line'),
    (v_user5a, 'er_5a@nycu.edu.tw', 'NYCU', 'Er 5a', 'https://avatar.er_5a', 'MASTER', 'er_5a_line'),
    (v_user5b, 'er_5b@nycu.edu.tw', 'NYCU', 'Er 5b', 'https://avatar.er_5b', 'MASTER', 'er_5b_line');

  select id into v_act_type_id from activity_type where name = '吃飯/咖啡/探店' limit 1;
  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '學生活動中心', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  -- req1: allow_downgrade=false，min=4，1 人，已過期
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user1, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '5 minutes', 4, 4, false, 'REQUESTING')
  returning * into v_req1;
  insert into request_member (request_id, user_id, role, status) values (v_req1.id, v_user1, 'OWNER', 'JOINED');

  -- req2: allow_downgrade=true，min=5，2 人，latest_start 剛過 1 分鐘（< 10 分鐘寬限期）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user2a, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 minute', 5, 5, true, 'REQUESTING')
  returning * into v_req2;
  insert into request_member (request_id, user_id, role, status) values
    (v_req2.id, v_user2a, 'OWNER', 'JOINED'), (v_req2.id, v_user2b, 'MEMBER', 'JOINED');

  -- req3: allow_downgrade=true，min=5，1 人，latest_start 已過期 20 分鐘（超過 10 分鐘寬限期）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user3, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '20 minutes', 5, 5, true, 'REQUESTING')
  returning * into v_req3;
  insert into request_member (request_id, user_id, role, status) values (v_req3.id, v_user3, 'OWNER', 'JOINED');

  -- req4: allow_downgrade=true，min=5，1 人，已過期，但先前已經有一筆 REJECTED 的
  -- downgrade_request（模擬「問過一次、對方拒絕」的情境）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user4, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 minute', 5, 5, true, 'REQUESTING')
  returning * into v_req4;
  insert into request_member (request_id, user_id, role, status) values (v_req4.id, v_user4, 'OWNER', 'JOINED');
  insert into downgrade_request (request_id, target_size, expire_at, status)
  values (v_req4.id, 2, now() - interval '30 minutes', 'REJECTED')
  returning id into v_dg4;

  -- req5: min=2，實際 2 人已達標，latest_start 已過（自給自足邊緣情況，不應被動）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, allow_downgrade, status)
  values (v_user5a, v_act_type_id, 'NYCU', v_campus, now() - interval '2 hours', now() - interval '1 minute', 2, 2, true, 'REQUESTING')
  returning * into v_req5;
  insert into request_member (request_id, user_id, role, status) values
    (v_req5.id, v_user5a, 'OWNER', 'JOINED'), (v_req5.id, v_user5b, 'MEMBER', 'JOINED');

  update fixtures set
    act_type_id = v_act_type_id, campus = v_campus,
    req1_id = v_req1.id, user1_id = v_user1,
    req2_id = v_req2.id, user2a_id = v_user2a, user2b_id = v_user2b,
    req3_id = v_req3.id, user3_id = v_user3,
    req4_id = v_req4.id, user4_id = v_user4, dg4_id = v_dg4,
    req5_id = v_req5.id, user5a_id = v_user5a, user5b_id = v_user5b;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 執行 fn_expire_requests()
-- -----------------------------------------------------------------------------

select cmp_ok(fn_expire_requests(), '>=', 1, 'fn_expire_requests 應處理過期記錄');

-- 1. req1（allow_downgrade=false）→ 直接 EXPIRED
select is(
  (select status::text from match_request where id = (select req1_id from fixtures)),
  'EXPIRED',
  'allow_downgrade=false 的過期 Request 應直接轉 EXPIRED'
);

select is(
  (select count(*)::int from downgrade_request where request_id = (select req1_id from fixtures)),
  0,
  'allow_downgrade=false 不應建立任何 downgrade_request'
);

-- 2. req2（allow_downgrade=true，剛過期不久）→ 建立 downgrade_request，
--    match_request 仍留在 REQUESTING（Downgrade 子流程不改變 match_request.status）
select is(
  (select status::text from match_request where id = (select req2_id from fixtures)),
  'REQUESTING',
  '剛過期且符合條件時，match_request 應仍留在 REQUESTING（等待 downgrade 回應）'
);

select is(
  (select target_size from downgrade_request where request_id = (select req2_id from fixtures)),
  2,
  'target_size 應為 greatest(2, 實際 JOINED 人數) = greatest(2, 2) = 2'
);

select is(
  (select count(*)::int from downgrade_consent dc
     join downgrade_request dg on dg.id = dc.downgrade_request_id
    where dg.request_id = (select req2_id from fixtures)),
  2,
  '應為 req2 的兩位 JOINED 成員都建立 downgrade_consent 記錄'
);

select is(
  (select count(*)::int from notification
    where event_type = 'DOWNGRADE_REQUEST'
      and user_id in ((select user2a_id from fixtures), (select user2b_id from fixtures))),
  2,
  '建立 downgrade_request 應向雙方各發一則 DOWNGRADE_REQUEST 通知'
);

-- 3. req3（allow_downgrade=true，但已過期超過寬限期）→ 直接 EXPIRED，不提供 downgrade
select is(
  (select status::text from match_request where id = (select req3_id from fixtures)),
  'EXPIRED',
  '已過期超過 downgrade_consent_window_minutes 寬限期，即使 allow_downgrade=true 也不再提供，直接 EXPIRED'
);

select is(
  (select count(*)::int from downgrade_request where request_id = (select req3_id from fixtures)),
  0,
  '超過寬限期不應建立 downgrade_request'
);

-- 4. req4（已有一筆 REJECTED 的 downgrade_request）→ 不再問第二次，直接 EXPIRED
select is(
  (select status::text from match_request where id = (select req4_id from fixtures)),
  'EXPIRED',
  '已經問過一次 downgrade 且被 REJECTED，不應再問第二次，直接 EXPIRED'
);

-- 5. req5（自給自足邊緣情況：實際人數已達 min_participants）→ 不動它，仍是 REQUESTING
select is(
  (select status::text from match_request where id = (select req5_id from fixtures)),
  'REQUESTING',
  '實際 JOINED 人數已達 min_participants 的過期 Request 不屬於 R4，這輪不動它'
);

select * from finish();

rollback;
