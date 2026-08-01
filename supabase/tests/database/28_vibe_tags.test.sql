-- =============================================================================
-- pgTAP Test — Vibe Tags (update_vibe_tags) — v1.28
--
-- 涵蓋：
-- 1. 成功設定 tags
-- 2. 覆寫（不是 append-only）——第二次呼叫取代第一次的內容
-- 3. 空陣列清空（正規化為 null）
-- 4. 超過 3 個標籤應被 TOO_MANY_TAGS (INVALID_INPUT) 擋下
-- 5. 單一標籤超過 20 字應被 TAG_TOO_LONG (INVALID_INPUT) 擋下
-- 6. 非活動成員應被 NOT_ACTIVITY_MEMBER 擋下
-- 7. COMPLETED 的活動不可再設定
-- 8. 不觸發任何通知（個人化欄位）
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
  m1_id        uuid,
  outsider_id  uuid,
  c1_id        uuid,
  act_type_id  uuid,
  campus       text,
  activity1_id uuid,
  activity2_id uuid
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_m1          uuid := gen_random_uuid();
  v_outsider    uuid := gen_random_uuid();
  v_c1          uuid := gen_random_uuid();
  v_act_type_id uuid;
  v_campus      text := 'VT測試區';
  v_req1        uuid;
  v_req2        uuid;
  v_activity1   activity;
  v_activity2   activity;
begin
  select id into v_act_type_id from activity_type where name = '籃球' limit 1;

  insert into auth.users (id, email) values
    (v_m1, 'vt_m1@nycu.edu.tw'), (v_outsider, 'vt_outsider@nycu.edu.tw'), (v_c1, 'vt_c1@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_m1, 'vt_m1@nycu.edu.tw', 'NYCU', 'Vt M1', 'https://avatar.vt_m1', 'MASTER', 'vt_m1_line'),
    (v_outsider, 'vt_outsider@nycu.edu.tw', 'NYCU', 'Vt Outsider', 'https://avatar.vt_outsider', 'MASTER', 'vt_outsider_line'),
    (v_c1, 'vt_c1@nycu.edu.tw', 'NYCU', 'Vt C1', 'https://avatar.vt_c1', 'MASTER', 'vt_c1_line');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_m1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req1;
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_c1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req2;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity1;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity1.id, v_m1, v_req1, 'JOINED');

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() - interval '3 hours', now() - interval '2 hours', 'COMPLETED')
  returning * into v_activity2;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  values (v_activity2.id, v_c1, v_req2, 'JOINED');

  update fixtures set
    m1_id = v_m1, outsider_id = v_outsider, c1_id = v_c1, act_type_id = v_act_type_id,
    campus = v_campus, activity1_id = v_activity1.id, activity2_id = v_activity2.id;
end;
$setup$;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select m1_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 成功設定
-- -----------------------------------------------------------------------------

do $$ begin
  perform update_vibe_tags((select activity1_id from fixtures), array['新手歡樂場', '流汗就好']);
end $$;

select is(
  (select vibe_tags from activity_member
    where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures)),
  array['新手歡樂場', '流汗就好'],
  '成功設定後 vibe_tags 應正確寫入'
);

-- -----------------------------------------------------------------------------
-- 2. 覆寫（不是 append-only）
-- -----------------------------------------------------------------------------

do $$ begin
  perform update_vibe_tags((select activity1_id from fixtures), array['認真拼戰']);
end $$;

select is(
  (select vibe_tags from activity_member
    where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures)),
  array['認真拼戰'],
  '第二次呼叫應覆寫，不是累加'
);

-- -----------------------------------------------------------------------------
-- 3. 空陣列清空
-- -----------------------------------------------------------------------------

do $$ begin
  perform update_vibe_tags((select activity1_id from fixtures), array[]::text[]);
end $$;

select is(
  (select vibe_tags from activity_member
    where activity_id = (select activity1_id from fixtures) and user_id = (select m1_id from fixtures)),
  null,
  '空陣列應正規化為 null（清空）'
);

-- -----------------------------------------------------------------------------
-- 4. 超過 3 個標籤
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select update_vibe_tags(%L, array['a','b','c','d'])$sql$, (select activity1_id from fixtures)),
  'INVALID_INPUT',
  '超過 3 個標籤應被 TOO_MANY_TAGS (INVALID_INPUT) 擋下'
);

-- -----------------------------------------------------------------------------
-- 5. 單一標籤超過 20 字
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select update_vibe_tags(%L, array[%L])$sql$, (select activity1_id from fixtures), repeat('字', 21)),
  'INVALID_INPUT',
  '單一標籤超過 20 字應被 TAG_TOO_LONG (INVALID_INPUT) 擋下'
);

-- -----------------------------------------------------------------------------
-- 6. 非活動成員
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select outsider_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_vibe_tags(%L, array['認真拼戰'])$sql$, (select activity1_id from fixtures)),
  'NOT_ACTIVITY_MEMBER',
  '非活動成員應被 NOT_ACTIVITY_MEMBER 擋下'
);

-- -----------------------------------------------------------------------------
-- 7. COMPLETED 的活動不可再設定
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select c1_id::text from fixtures), true);
end $$;

select throws_ok(
  format($sql$select update_vibe_tags(%L, array['純吃美食'])$sql$, (select activity2_id from fixtures)),
  'ACTIVITY_NOT_ACTIVE',
  'COMPLETED 的活動不可再設定 vibe_tags，應被 ACTIVITY_NOT_ACTIVE 擋下'
);

-- -----------------------------------------------------------------------------
-- 8. 不觸發任何通知（個人化欄位）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from notification where user_id = (select m1_id from fixtures)),
  0,
  '設定 vibe_tags 不應觸發任何通知'
);

select * from finish();

rollback;
