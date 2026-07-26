-- =============================================================================
-- pgTAP Test — Meeting Point / Meeting Hint (docs/API.md §6.6/6.7, SPEC §9.2, v1.11.1)
-- 涵蓋：NOT_ACTIVITY_MEMBER、成功更新（append-only 記錄 + 通知全體）、
-- 2 分鐘冷卻（同一人擋下、不同人不受影響）、目前集合點取最新一筆、
-- Meeting Hint 更新與 30 字上限（RPC 層 INVALID_INPUT + DB 層 CHECK 約束雙重防線）、
-- RLS 可見性（活動全體成員公開透明）、COMPLETED/CANCELLED 邊界（不可再修改）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(15);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  m1_id           uuid,  -- activity_1 (MATCHED) member
  m2_id           uuid,  -- activity_1 (MATCHED) member
  outsider_id     uuid,  -- 完全不是任何活動的成員
  c1_id           uuid,  -- activity_2 (COMPLETED) member
  x1_id           uuid,  -- activity_3 (CANCELLED) member
  act_type_id     uuid,
  campus          text,
  activity1_id    uuid,
  activity2_id    uuid,
  activity3_id    uuid
);
insert into fixtures default values;

-- 測試 10/11 會 `set local role authenticated` 來實測 RLS，該角色也要能讀
-- 這張 temp fixtures 表才能取得各 fixture id（比照 05_propose_location.test.sql）
grant select on fixtures to authenticated;

do $setup$
declare
  v_m1        uuid := gen_random_uuid();
  v_m2        uuid := gen_random_uuid();
  v_outsider  uuid := gen_random_uuid();
  v_c1        uuid := gen_random_uuid();
  v_x1        uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := '光復';
  v_req1        uuid;
  v_req2        uuid;
  v_req3        uuid;
  v_activity1   activity;
  v_activity2   activity;
  v_activity3   activity;
begin
  insert into auth.users (id, email) values
    (v_m1, 'mp_m1@nycu.edu.tw'), (v_m2, 'mp_m2@nycu.edu.tw'),
    (v_outsider, 'mp_outsider@nycu.edu.tw'),
    (v_c1, 'mp_c1@nycu.edu.tw'), (v_x1, 'mp_x1@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_m1, 'mp_m1@nycu.edu.tw', 'NYCU', 'Mp M1', 'https://avatar.mp_m1', 'MASTER', 'mp_m1_line'),
    (v_m2, 'mp_m2@nycu.edu.tw', 'NYCU', 'Mp M2', 'https://avatar.mp_m2', 'MASTER', 'mp_m2_line'),
    (v_outsider, 'mp_outsider@nycu.edu.tw', 'NYCU', 'Mp Outsider', 'https://avatar.mp_outsider', 'MASTER', 'mp_outsider_line'),
    (v_c1, 'mp_c1@nycu.edu.tw', 'NYCU', 'Mp C1', 'https://avatar.mp_c1', 'MASTER', 'mp_c1_line'),
    (v_x1, 'mp_x1@nycu.edu.tw', 'NYCU', 'Mp X1', 'https://avatar.mp_x1', 'MASTER', 'mp_x1_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  -- activity_member.source_request_id 是 NOT NULL FK → match_request，各建一筆
  -- 已 MATCHED 的 match_request 當來源（測試不關心撮合細節，只需要滿足 FK）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req1;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_c1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req2;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_x1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req3;

  -- activity_1：MATCHED，2 位成員，主要 happy-path / 冷卻 / hint / RLS 測試
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity1;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity1.id, u, v_req1, 'JOINED' from unnest(array[v_m1, v_m2]) as u;

  -- activity_2：COMPLETED，測邊界（不可再修改）
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 'COMPLETED')
  returning * into v_activity2;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity2.id, v_c1, v_req2, 'JOINED');

  -- activity_3：CANCELLED，測邊界（不可再修改）
  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'CANCELLED')
  returning * into v_activity3;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity3.id, v_x1, v_req3, 'JOINED');

  update fixtures set
    m1_id = v_m1, m2_id = v_m2, outsider_id = v_outsider, c1_id = v_c1, x1_id = v_x1,
    act_type_id = v_act_type_id, campus = v_campus,
    activity1_id = v_activity1.id, activity2_id = v_activity2.id, activity3_id = v_activity3.id;
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1. 非活動成員呼叫 update_meeting_point 應被 NOT_ACTIVITY_MEMBER 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_meeting_point(%L, %L)$sql$,
    (select activity1_id from fixtures), '光復北大門'),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員呼叫 update_meeting_point 應被 NOT_ACTIVITY_MEMBER 擋下'
);

-- -----------------------------------------------------------------------------
-- 2. m1 成功更新集合點 — 應建立一筆 append-only 記錄
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
  perform update_meeting_point((select activity1_id from fixtures), '光復北大門');
end $$;

select is(
  (select description from activity_meeting_point_update
    where activity_id = (select activity1_id from fixtures) and updated_by = (select m1_id from fixtures)
    order by created_at desc limit 1),
  '光復北大門',
  'm1 成功更新集合點後應建立對應記錄'
);

-- -----------------------------------------------------------------------------
-- 3. m1 立刻再次更新應被 2 分鐘冷卻擋下（同一人）
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select update_meeting_point(%L, %L)$sql$,
    (select activity1_id from fixtures), '改成二餐門口'),
  'MEETING_POINT_UPDATE_COOLDOWN',
  '同一人 2 分鐘內連續更新集合點應被冷卻擋下'
);

-- -----------------------------------------------------------------------------
-- 4. m2（不同人）更新不應受 m1 冷卻影響
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m2_id::text from fixtures), true);
  perform update_meeting_point((select activity1_id from fixtures), '浩然圖書館門口');
end $$;

select is(
  (select description from activity_meeting_point_update
    where activity_id = (select activity1_id from fixtures) and updated_by = (select m2_id from fixtures)
    order by created_at desc limit 1),
  '浩然圖書館門口',
  '冷卻是每人各自計算，m2 不受 m1 冷卻影響，應可成功更新'
);

-- -----------------------------------------------------------------------------
-- 5. 「目前集合點」查詢（依 created_at 取最新一筆）應為 m2 剛更新的內容
-- -----------------------------------------------------------------------------

select is(
  (select description from activity_meeting_point_update
    where activity_id = (select activity1_id from fixtures)
    order by created_at desc limit 1),
  '浩然圖書館門口',
  '目前集合點＝依 created_at 取最新一筆，應為 m2 剛更新的內容'
);

-- -----------------------------------------------------------------------------
-- 6. 兩次成功更新都應通知全體成員 — m1 應收到 2 則 MEETING_POINT_UPDATED
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from notification
    where user_id = (select m1_id from fixtures)
      and event_type = 'MEETING_POINT_UPDATED'
      and (payload->>'activity_id')::uuid = (select activity1_id from fixtures)),
  2,
  '每次成功更新集合點都應通知全體成員，m1 應收到 2 則 MEETING_POINT_UPDATED'
);

-- -----------------------------------------------------------------------------
-- 7. m1 成功設定 Meeting Hint
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
  perform update_meeting_hint((select activity1_id from fixtures), '穿紅色外套，帶著筆電');
end $$;

select is(
  (select meeting_hint from activity_member
    where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures)),
  '穿紅色外套，帶著筆電',
  'm1 成功設定 Meeting Hint 後 activity_member.meeting_hint 應正確寫入'
);

-- -----------------------------------------------------------------------------
-- 8. Meeting Hint 超過 30 字應被 INVALID_INPUT 擋下（RPC 層）
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select update_meeting_hint(%L, %L)$sql$,
    (select activity1_id from fixtures), repeat('提', 31)),
  'INVALID_INPUT',
  'Meeting Hint 超過 30 字應被 RPC 層 INVALID_INPUT 擋下'
);

-- -----------------------------------------------------------------------------
-- 9. 非活動成員呼叫 update_meeting_hint 應被 NOT_ACTIVITY_MEMBER 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_meeting_hint(%L, %L)$sql$,
    (select activity1_id from fixtures), '路過留言'),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員呼叫 update_meeting_hint 應被 NOT_ACTIVITY_MEMBER 擋下'
);

-- -----------------------------------------------------------------------------
-- 10/11. RLS：活動成員可見，非成員不可見（公開透明給全體成員，比照
--        activity_location_option/vote，不比照 pending_confirmation 的不歸因設計）
-- -----------------------------------------------------------------------------

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select is(
  (select count(*)::int from activity_meeting_point_update
    where activity_id = (select activity1_id from fixtures)),
  0,
  'RLS：非活動成員看不到 activity_meeting_point_update 任何記錄'
);

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
end $$;

select is(
  (select count(*)::int from activity_meeting_point_update
    where activity_id = (select activity1_id from fixtures)),
  2,
  'RLS：活動成員看得到該活動全部的集合點更新記錄（2 筆）'
);

reset role;

-- -----------------------------------------------------------------------------
-- 12/13. 邊界：COMPLETED 的活動不可再修改集合點／提示
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select c1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_meeting_point(%L, %L)$sql$,
    (select activity2_id from fixtures), '任意地點'),
  'ACTIVITY_NOT_ACTIVE',
  'COMPLETED 的活動不可再更新集合點，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

select throws_ok(
  format($sql$select update_meeting_hint(%L, %L)$sql$,
    (select activity2_id from fixtures), '任意提示'),
  'ACTIVITY_NOT_ACTIVE',
  'COMPLETED 的活動不可再更新 Meeting Hint，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 14. 邊界：CANCELLED 的活動不可再修改集合點
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select x1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_meeting_point(%L, %L)$sql$,
    (select activity3_id from fixtures), '任意地點'),
  'ACTIVITY_NOT_ACTIVE',
  'CANCELLED 的活動不可再更新集合點，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 15. DB 層防線：meeting_hint 的 30 字上限同時是 CHECK 約束，不只是 RPC 層檢查
--     （繞過 RPC 直接 UPDATE 也應被擋下，確認雙重防線都存在）
-- -----------------------------------------------------------------------------

reset role;

select throws_matching(
  format($sql$update activity_member set meeting_hint = %L where activity_id = %L and user_id = %L$sql$,
    repeat('x', 31), (select activity1_id from fixtures), (select m1_id from fixtures)),
  'violates check constraint "activity_member_meeting_hint_check"',
  'meeting_hint 超過 30 字即使繞過 RPC 直接 UPDATE，也應被 DB 層 CHECK 約束擋下'
);

select * from finish();

rollback;
