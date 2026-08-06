-- =============================================================================
-- pgTAP Test — Campus Activity Pulse (get_campus_pulse) — v1.26 / v1.39
--
-- 涵蓋：
-- 1. 只計算 REQUESTING（DRAFT/PENDING_CONFIRMATION/MATCHED 皆不計入）
-- 2. 正確依 (school, campus) 分組，不混到其他校區
-- 3. 同活動類型多筆 REQUESTING 正確加總（依人頭，不是依 Request 筆數）
-- 4. 零筆的活動類型完全不出現在結果中（不是回傳 count=0）
-- 5. v1.39：單一 Request 已透過邀請連結帶多位 request_member，要算進全部人頭，
--    不是只算 1（原本用 count(*) 數 match_request 列數的 bug）
-- 6. v1.39：LEFT 狀態的 request_member 不計入人頭
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
  viewer_id        uuid,
  deleted_id       uuid,
  basketball_id    uuid,
  coffee_id        uuid,
  campus           text,
  other_campus     text,
  headcount_campus text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_viewer          uuid := gen_random_uuid();
  v_deleted         uuid := gen_random_uuid();
  v_owner1          uuid := gen_random_uuid();
  v_owner2          uuid := gen_random_uuid();
  v_owner3          uuid := gen_random_uuid();
  v_owner4          uuid := gen_random_uuid();
  v_owner5          uuid := gen_random_uuid();
  v_owner6          uuid := gen_random_uuid();
  v_invitee1        uuid := gen_random_uuid();
  v_invitee2        uuid := gen_random_uuid();
  v_left_invitee    uuid := gen_random_uuid();
  v_owner7          uuid := gen_random_uuid();
  v_left_invitee2   uuid := gen_random_uuid();
  v_basketball_id   uuid;
  v_coffee_id       uuid;
  v_campus          text := 'CP測試區';
  v_other_campus    text := 'CP其他區';
  v_headcount_campus text := 'CP人頭測試區';
  v_request1        uuid;
  v_request2        uuid;
  v_request3        uuid;
  v_request4        uuid;
  v_request5        uuid;
  v_request6        uuid;
  v_request7        uuid;
  v_request8        uuid;
begin
  select id into v_basketball_id from activity_type where name = '籃球' limit 1;
  select id into v_coffee_id from activity_type where name = '咖啡' limit 1;

  insert into auth.users (id, email) values
    (v_viewer, 'cp_viewer@nycu.edu.tw'), (v_deleted, 'cp_deleted@nycu.edu.tw'), (v_owner1, 'cp_o1@nycu.edu.tw'),
    (v_owner2, 'cp_o2@nycu.edu.tw'), (v_owner3, 'cp_o3@nycu.edu.tw'), (v_owner4, 'cp_o4@nycu.edu.tw'),
    (v_owner5, 'cp_o5@nycu.edu.tw'), (v_owner6, 'cp_o6@nycu.edu.tw'), (v_invitee1, 'cp_i1@nycu.edu.tw'),
    (v_invitee2, 'cp_i2@nycu.edu.tw'), (v_left_invitee, 'cp_left1@nycu.edu.tw'),
    (v_owner7, 'cp_o7@nycu.edu.tw'), (v_left_invitee2, 'cp_left2@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  select u, u::text || '@nycu.edu.tw', 'NYCU', 'CP ' || u::text, 'https://avatar.cp', 'UNDERGRAD', 'cp_ig'
    from unnest(array[v_viewer, v_deleted, v_owner1, v_owner2, v_owner3, v_owner4, v_owner5, v_owner6,
      v_invitee1, v_invitee2, v_left_invitee, v_owner7, v_left_invitee2]) as u;

  update app_user
     set email = 'deleted+' || v_deleted::text, deleted_at = now()
   where id = v_deleted;

  -- 2 筆籃球 REQUESTING（同校區），各自只有 owner 本人（1 人頭）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values
    (v_owner1, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request1;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner2, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request2;

  -- 1 筆咖啡 REQUESTING（同校區）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner3, v_coffee_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request3;

  -- 1 筆咖啡 DRAFT（同校區，不應計入——未送出）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner4, v_coffee_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'DRAFT')
    returning id into v_request4;

  -- 1 筆籃球 MATCHED（同校區，不應計入——已成局）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner1, v_basketball_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
    returning id into v_request5;

  -- 1 筆籃球 REQUESTING（不同校區，不應計入這次查詢）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner5, v_basketball_id, 'NYCU', v_other_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request6;

  -- v1.39：1 筆籃球 REQUESTING（獨立的人頭測試校區），owner 已透過邀請連結
  -- 帶了 2 位已加入的朋友 + 1 位已退出的朋友——只有 1 筆 match_request 列，
  -- 但應算 3 人頭（owner + 2 位 JOINED），不是 1（列數）也不是 4（含 LEFT）
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner6, v_basketball_id, 'NYCU', v_headcount_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request7;

  -- v1.39：1 筆咖啡 REQUESTING（同一人頭測試校區），owner 的唯一邀請對象已退出
  -- ——應算 1 人頭（僅 owner），驗證 LEFT 不會被誤算進去
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner7, v_coffee_id, 'NYCU', v_headcount_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
    returning id into v_request8;

  -- 所有 match_request 都比照真實 create_request 流程，補上 owner 的
  -- request_member（JOINED）——否則改成 join request_member 的新查詢邏輯下，
  -- 這幾筆會被誤判成「沒人加入」而完全不計入。
  insert into request_member (request_id, user_id, role, status) values
    (v_request1, v_owner1, 'OWNER', 'JOINED'),
    (v_request2, v_owner2, 'OWNER', 'JOINED'),
    (v_request3, v_owner3, 'OWNER', 'JOINED'),
    (v_request5, v_owner1, 'OWNER', 'JOINED'),
    (v_request6, v_owner5, 'OWNER', 'JOINED'),
    (v_request7, v_owner6, 'OWNER', 'JOINED'),
    (v_request7, v_invitee1, 'MEMBER', 'JOINED'),
    (v_request7, v_invitee2, 'MEMBER', 'JOINED'),
    (v_request7, v_left_invitee, 'MEMBER', 'LEFT'),
    (v_request8, v_owner7, 'OWNER', 'JOINED'),
    (v_request8, v_left_invitee2, 'MEMBER', 'LEFT');

  update fixtures set
    viewer_id = v_viewer, deleted_id = v_deleted, basketball_id = v_basketball_id, coffee_id = v_coffee_id,
    campus = v_campus, other_campus = v_other_campus, headcount_campus = v_headcount_campus;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select viewer_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 籃球應為 2（只算 REQUESTING，MATCHED 不計入）
-- -----------------------------------------------------------------------------

select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select basketball_id from fixtures)),
  2,
  '籃球 REQUESTING 應為 2，MATCHED 的那筆不計入'
);

-- -----------------------------------------------------------------------------
-- 2. 咖啡應為 1（DRAFT 不計入）
-- -----------------------------------------------------------------------------

select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  1,
  '咖啡 REQUESTING 應為 1，DRAFT 的那筆不計入'
);

-- -----------------------------------------------------------------------------
-- 3. 不同校區的 REQUESTING 不應混進來——other_campus 查詢應只看到籃球 1 筆
-- -----------------------------------------------------------------------------

select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select other_campus from fixtures))
    where activity_type_id = (select basketball_id from fixtures)),
  1,
  '不同校區應分開計算，other_campus 的籃球應為 1'
);

-- -----------------------------------------------------------------------------
-- 4. other_campus 查詢裡咖啡應完全不出現（零筆，不是 count=0 的一列）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from get_campus_pulse('NYCU'::school, (select other_campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  0,
  '零筆的活動類型完全不應出現在結果列中'
);

-- -----------------------------------------------------------------------------
-- 5. v1.39：單一 Request 已透過邀請連結帶 2 位 JOINED 朋友（另有 1 位 LEFT）——
--    只有 1 筆 match_request 列，但應算 3 人頭，不是 1（列數）也不是 4（含 LEFT）
-- -----------------------------------------------------------------------------

select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select headcount_campus from fixtures))
    where activity_type_id = (select basketball_id from fixtures)),
  3,
  '單一 Request 帶 2 位 JOINED 朋友應算 3 人頭，不是 1 筆 Request 也不是含 LEFT 的 4 人'
);

-- -----------------------------------------------------------------------------
-- 6. v1.39：owner 唯一邀請對象已 LEFT，應只算 1 人頭（僅 owner），不是 2
-- -----------------------------------------------------------------------------

select is(
  (select person_count from get_campus_pulse('NYCU'::school, (select headcount_campus from fixtures))
    where activity_type_id = (select coffee_id from fixtures)),
  1,
  '唯一邀請對象已 LEFT，應只算 owner 1 人頭'
);

-- -----------------------------------------------------------------------------
-- 7. 已刪除帳號呼叫 get_campus_pulse 應被 ACCOUNT_DELETED 擋下
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select deleted_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select * from get_campus_pulse('NYCU'::school, %L)$sql$, (select campus from fixtures)),
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫 get_campus_pulse 應被 ACCOUNT_DELETED 擋下'
);

select * from finish();

rollback;
