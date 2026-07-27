-- =============================================================================
-- pgTAP Test — delete_account() (docs/API.md §1.5, SPEC v1.14)
--
-- 涵蓋（對應對話中逐表判斷的核心主張，不是隨便測幾個欄位）：
--   ① app_user 去識別化：email/display_name/avatar_url/gender/bio/department/
--      contact_* 清空或改佔位值，deleted_at 寫入；degree_level/school 刻意
--      保留不清（見設計判斷）
--   ② owner 名下仍在 REQUESTING 的 request → 自動 CANCELLED，其他已加入成員
--      的 request_member 不受影響（仍是 JOINED）
--   ③ 非 owner 成員在別人仍在 REQUESTING 的 request 上 → 自己的 request_member
--      變 LEFT，該 request 本身（owner 是別人）不受影響，仍是 REQUESTING
--   ④ MATCHED activity 上的成員 → activity_member 變 CANCELLED，且刻意不寫
--      Reliability 事件（不是失信行為）；同活動另一位成員的 activity_member
--      不受影響
--   ⑤ 核心主張：其他成員依賴的共用資料（地點提案/得票）在刪除者是提案人/
--      投票人時完全不受影響——這是「app_user row 保留、id 不變」整個架構決定
--      要驗證的東西，不是隨便帶過
--   ⑥ 純屬自己的 notification 收件匣清空，其他成員的 notification 不受影響
--   ⑦ match_history_avoidance 涉及刪除者的 pair 被清掉
--   ⑧ 冪等：重複呼叫 delete_account() 回傳 already_deleted=true、不報錯
--   ⑨ 所有身分驗證類 RPC 補上的 ACCOUNT_DELETED 檢查，實際擋下一支代表性 RPC
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(23);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  act_type_id     uuid,
  campus          text,
  owner_id        uuid,  -- 名下有仍在 REQUESTING 的 request，將被刪除
  member1_id      uuid,  -- owner 那個 request 的其他已加入成員，不該受影響
  req_owned_id    uuid,
  other_owner_id  uuid,  -- 別人 request 的 owner，不該受影響
  member2_id      uuid,  -- 別人 request 上的非 owner 成員，將被刪除
  req_other_id    uuid,
  actor1_id       uuid,  -- MATCHED activity 的成員，將被刪除；有提案+投票地點
  actor2_id       uuid,  -- 同一活動的另一個成員，不該受影響
  activity_id     uuid,
  bystander_id    uuid,  -- match_history_avoidance 的另一方，只需存在滿足 FK
  loc_id          uuid,
  original_degree text,
  original_school text
);
insert into fixtures default values;
grant select on fixtures to authenticated;

do $setup$
declare
  v_owner        uuid := gen_random_uuid();
  v_member1      uuid := gen_random_uuid();
  v_other_owner  uuid := gen_random_uuid();
  v_member2      uuid := gen_random_uuid();
  v_actor1       uuid := gen_random_uuid();
  v_actor2       uuid := gen_random_uuid();
  v_bystander    uuid := gen_random_uuid();
  v_act_type_id  uuid;
  v_campus       text := '光復';
  v_req_owned    uuid;
  v_req_other    uuid;
  v_req_act      uuid;
  v_activity     activity;
  v_loc_id       uuid;
  v_pc_id        uuid;
begin
  insert into auth.users (id, email) values
    (v_owner, 'da_owner@nycu.edu.tw'), (v_member1, 'da_member1@nycu.edu.tw'),
    (v_other_owner, 'da_other_owner@nycu.edu.tw'), (v_member2, 'da_member2@nycu.edu.tw'),
    (v_actor1, 'da_actor1@nycu.edu.tw'), (v_actor2, 'da_actor2@nycu.edu.tw'),
    (v_bystander, 'da_bystander@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
    (v_owner, 'da_owner@nycu.edu.tw', 'NYCU', 'Da Owner', 'https://avatar.da_owner', 'MASTER', 'da_owner_line'),
    (v_member1, 'da_member1@nycu.edu.tw', 'NYCU', 'Da Member1', 'https://avatar.da_member1', 'MASTER', 'da_member1_line'),
    (v_other_owner, 'da_other_owner@nycu.edu.tw', 'NYCU', 'Da OtherOwner', 'https://avatar.da_other_owner', 'MASTER', 'da_other_owner_line'),
    (v_member2, 'da_member2@nycu.edu.tw', 'NYCU', 'Da Member2', 'https://avatar.da_member2', 'MASTER', 'da_member2_line'),
    (v_actor1, 'da_actor1@nycu.edu.tw', 'NYCU', 'Da Actor1', 'https://avatar.da_actor1', 'MASTER', 'da_actor1_line'),
    (v_actor2, 'da_actor2@nycu.edu.tw', 'NYCU', 'Da Actor2', 'https://avatar.da_actor2', 'MASTER', 'da_actor2_line'),
    (v_bystander, 'da_bystander@nycu.edu.tw', 'NYCU', 'Da Bystander', 'https://avatar.da_bystander', 'MASTER', 'da_bystander_line');

  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;
  select id into v_loc_id from location where school = 'NYCU' and campus = v_campus and status = 'APPROVED' limit 1;

  -- owner 名下仍在 REQUESTING 的 request，member1 是已加入成員
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_owner, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
  returning id into v_req_owned;
  insert into request_member (request_id, user_id, role, status) values
    (v_req_owned, v_owner, 'OWNER', 'JOINED'),
    (v_req_owned, v_member1, 'MEMBER', 'JOINED');

  -- other_owner 名下仍在 REQUESTING 的 request，member2 是非 owner 已加入成員
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_other_owner, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'REQUESTING')
  returning id into v_req_other;
  insert into request_member (request_id, user_id, role, status) values
    (v_req_other, v_other_owner, 'OWNER', 'JOINED'),
    (v_req_other, v_member2, 'MEMBER', 'JOINED');

  -- MATCHED activity：actor1、actor2 都是成員；actor1 額外提案 + 投票一個候選地點
  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_actor1, v_act_type_id, 'NYCU', v_campus, now(), now() + interval '2 hours', 2, 4, 'MATCHED')
  returning id into v_req_act;

  insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
  values (v_act_type_id, 'NYCU', v_campus, now() + interval '1 hour', now() + interval '2 hours', 'MATCHED')
  returning * into v_activity;
  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity.id, u, v_req_act, 'JOINED' from unnest(array[v_actor1, v_actor2]) as u;

  insert into activity_location_option (activity_id, location_id, proposed_by)
  values (v_activity.id, v_loc_id, v_actor1);
  insert into activity_location_vote (activity_id, user_id, location_id)
  values (v_activity.id, v_actor1, v_loc_id);

  -- actor1/actor2 各自的通知收件匣（各一筆）
  insert into notification (user_id, event_type, payload) values
    (v_actor1, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)),
    (v_actor2, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id));

  -- match_history_avoidance：actor1 跟 bystander 之間的一筆（正規化排序），
  -- source_pending_confirmation_id 是 NOT NULL FK，隨便建一筆滿足即可
  insert into pending_confirmation (request_a_id, request_b_id, confirm_window_expire_at, status)
  values (v_req_owned, v_req_other, now() + interval '10 minutes', 'DECLINED')
  returning id into v_pc_id;

  insert into match_history_avoidance (user_a_id, user_b_id, source_pending_confirmation_id)
  values (least(v_actor1, v_bystander), greatest(v_actor1, v_bystander), v_pc_id);

  update fixtures set
    act_type_id = v_act_type_id, campus = v_campus,
    owner_id = v_owner, member1_id = v_member1, req_owned_id = v_req_owned,
    other_owner_id = v_other_owner, member2_id = v_member2, req_other_id = v_req_other,
    actor1_id = v_actor1, actor2_id = v_actor2, activity_id = v_activity.id,
    bystander_id = v_bystander, loc_id = v_loc_id,
    original_degree = 'MASTER', original_school = 'NYCU';
end;
$setup$;

-- -----------------------------------------------------------------------------
-- 1/2. owner 呼叫 delete_account()：回傳 success=true, had_profile=true
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

select is(
  ((select delete_account())->>'success')::boolean,
  true,
  'owner 呼叫 delete_account() 應回傳 success=true'
);

-- -----------------------------------------------------------------------------
-- 3. req_owned（owner 名下仍在 REQUESTING）刪除後應被自動 CANCELLED
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select req_owned_id from fixtures)),
  'CANCELLED',
  'owner 名下仍在 REQUESTING 的 request 應在刪除帳號後自動 CANCELLED'
);

-- -----------------------------------------------------------------------------
-- 4. member1（owner 那個 request 的其他成員）不該受影響，仍是 JOINED
-- -----------------------------------------------------------------------------

select is(
  (select status::text from request_member
    where request_id = (select req_owned_id from fixtures) and user_id = (select member1_id from fixtures)),
  'JOINED',
  'owner 被刪除不該影響其他已加入成員的 request_member 狀態'
);

-- -----------------------------------------------------------------------------
-- 5/6. actor1 呼叫 delete_account()：activity_member 變 CANCELLED，
--      actor2（同活動另一成員）不受影響，仍是 JOINED
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select actor1_id::text from fixtures), true);
end $$;

select is(
  ((select delete_account())->>'had_profile')::boolean,
  true,
  'actor1 呼叫 delete_account() 應回傳 had_profile=true（曾完成過 onboarding）'
);

select is(
  (select status::text from activity_member
    where activity_id = (select activity_id from fixtures) and user_id = (select actor1_id from fixtures)),
  'CANCELLED',
  'actor1 在 MATCHED activity 上的 activity_member 應變成 CANCELLED'
);

-- -----------------------------------------------------------------------------
-- 7. member2（別人 request 上的非 owner 成員）呼叫 delete_account()：
--    自己的 request_member 變 LEFT
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select member2_id::text from fixtures), true);
  perform delete_account();
end $$;

select is(
  (select status::text from request_member
    where request_id = (select req_other_id from fixtures) and user_id = (select member2_id from fixtures)),
  'LEFT',
  '非 owner 成員刪除帳號後，自己的 request_member 應變 LEFT'
);

-- -----------------------------------------------------------------------------
-- 8. req_other（other_owner 名下）不該因為 member2（非 owner）被刪除而變動，
--    仍是 REQUESTING
-- -----------------------------------------------------------------------------

select is(
  (select status::text from match_request where id = (select req_other_id from fixtures)),
  'REQUESTING',
  '非 owner 成員被刪除不該影響 request 本身的狀態（owner 是別人）'
);

-- -----------------------------------------------------------------------------
-- 9. actor2（同活動另一成員）不受 actor1 刪除影響，仍是 JOINED
-- -----------------------------------------------------------------------------

select is(
  (select status::text from activity_member
    where activity_id = (select activity_id from fixtures) and user_id = (select actor2_id from fixtures)),
  'JOINED',
  '同活動另一成員不該因為 actor1 刪除帳號而受影響'
);

-- -----------------------------------------------------------------------------
-- 10. actor1 刪除帳號刻意不寫 Reliability 事件（不是失信行為，不比照
--     cancel_activity_participation 的懲罰邏輯）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from user_reliability_event
    where user_id = (select actor1_id from fixtures) and activity_id = (select activity_id from fixtures)),
  0,
  '帳號刪除不應為該活動寫入任何 user_reliability_event'
);

-- -----------------------------------------------------------------------------
-- 11/12. 核心主張：actor1 提案 + 投票的候選地點資料完全不受影響
--        （其他成員依賴的得票數不能因為提案人刪除帳號而失真）
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from activity_location_option
    where activity_id = (select activity_id from fixtures) and proposed_by = (select actor1_id from fixtures)),
  1,
  'actor1 提案的候選地點記錄不該因為刪除帳號而消失或被清空'
);

select is(
  (select count(*)::int from activity_location_vote
    where activity_id = (select activity_id from fixtures) and user_id = (select actor1_id from fixtures)),
  1,
  'actor1 投的票不該因為刪除帳號而消失，得票數才不會失真'
);

-- -----------------------------------------------------------------------------
-- 13/14. notification：actor1 自己的收件匣清空，actor2 的不受影響
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from notification where user_id = (select actor1_id from fixtures)),
  0,
  'actor1 自己的 notification 收件匣應在刪除帳號後清空'
);

select is(
  (select count(*)::int from notification where user_id = (select actor2_id from fixtures)),
  1,
  'actor2 的 notification 收件匣不該受 actor1 刪除帳號影響'
);

-- -----------------------------------------------------------------------------
-- 15. match_history_avoidance：涉及 actor1 的 pair 應被清掉
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_history_avoidance
    where (select actor1_id from fixtures) in (user_a_id, user_b_id)),
  0,
  '涉及 actor1 的 match_history_avoidance pair 應在刪除帳號後被清掉'
);

-- -----------------------------------------------------------------------------
-- 16-22. app_user 去識別化欄位驗證
-- -----------------------------------------------------------------------------

select ok(
  (select email from app_user where id = (select actor1_id from fixtures)) like 'deleted+%',
  'email 應改成 deleted+<uuid> 佔位值，不再是真實信箱'
);

select is(
  (select display_name from app_user where id = (select actor1_id from fixtures)),
  '已刪除的使用者',
  'display_name 應改成固定佔位字串'
);

select is(
  (select avatar_url from app_user where id = (select actor1_id from fixtures)),
  '',
  'avatar_url（NOT NULL 門檻）應改成空字串佔位'
);

select ok(
  (select gender is null and bio is null and department is null
     and contact_ig is null and contact_discord is null
     from app_user where id = (select actor1_id from fixtures)),
  'gender/bio/department/contact_ig/contact_discord 皆應清空為 NULL'
);

select is(
  (select contact_line from app_user where id = (select actor1_id from fixtures)),
  '[已刪除帳號]',
  'contact_line 應留一項佔位值以滿足 at_least_one_contact CHECK'
);

select ok(
  (select deleted_at is not null from app_user where id = (select actor1_id from fixtures)),
  'deleted_at 應寫入非 NULL 的刪除時間'
);

select ok(
  (select degree_level::text = (select original_degree from fixtures)
     and school::text = (select original_school from fixtures)
     from app_user where id = (select actor1_id from fixtures)),
  'degree_level/school 刻意保留不清（粗粒度分類，去識別化後不具單獨識別力）'
);

-- -----------------------------------------------------------------------------
-- 23. 冪等：actor1 重複呼叫 delete_account() 應回傳 already_deleted=true、不報錯
-- -----------------------------------------------------------------------------

select is(
  ((select delete_account())->>'already_deleted')::boolean,
  true,
  '重複呼叫 delete_account() 應被冪等判斷擋下，回傳 already_deleted=true'
);

-- -----------------------------------------------------------------------------
-- 24. 已刪除帳號呼叫任一身分驗證類 RPC 應被 ACCOUNT_DELETED 擋下
--     （挑 cancel_activity_participation 作代表；21 支 RPC 的清單見
--     20260724122600_delete_account_guard.sql 檔頭說明，不在此逐一重測）
-- -----------------------------------------------------------------------------

select throws_ok(
  format($sql$select cancel_activity_participation(%L)$sql$, (select activity_id from fixtures)),
  'ACCOUNT_DELETED',
  '已刪除帳號呼叫身分驗證類 RPC 應被 ACCOUNT_DELETED 擋下'
);

select * from finish();

rollback;
