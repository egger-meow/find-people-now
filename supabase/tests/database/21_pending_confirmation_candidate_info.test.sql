-- =============================================================================
-- pgTAP Test — get_pending_confirmation_candidate_info (docs/API.md §4.3, v1.22)
-- =============================================================================
-- Covers the gap found while scoping "我的活動" round 1: SPEC.md §12.1.3's
-- "安全資訊卡" (display_name/avatar_url/school/department/degree_level/
-- reliability_tier/completed_activity_count for the *other* party) never had
-- a backing RPC — get_pending_confirmation_status (4.1) only ever returned
-- the pending_confirmation's own status/countdown. This is the first test
-- coverage for the new RPC added in
-- 20260724125600_pending_confirmation_candidate_info.sql.
--
-- Assertions: symmetric visibility (each party sees the *other* party's
-- info, not their own), completed_activity_count reflects real ATTENDED
-- events (not a stub/default), a non-party caller gets FORBIDDEN, a bogus id
-- gets NOT_FOUND, and the response never includes user_a_response/
-- user_b_response (the unrelated symmetric-non-attribution guarantee 4.1
-- already provides must not regress just because this RPC exists).
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(9);

-- -----------------------------------------------------------------------------
-- 0. Setup — a PENDING_CONFIRMATION between owner A / owner B, plus an
--    unrelated stranger. Owner B has one real ATTENDED reliability event
--    (against a real, distinct COMPLETED activity) so
--    completed_activity_count is verifiably non-zero, not just absent.
-- -----------------------------------------------------------------------------

create temp table fixtures (
  a_owner_id uuid,
  b_owner_id uuid,
  stranger_id uuid,
  pc_id uuid
);
insert into fixtures default values;

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := 'PCI測試區';
  v_now         timestamptz := now();
  v_a_owner     uuid := gen_random_uuid();
  v_b_owner     uuid := gen_random_uuid();
  v_stranger    uuid := gen_random_uuid();
  v_req_a       match_request;
  v_req_b       match_request;
  v_pc          pending_confirmation;
  v_past_activity_id uuid;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into location (school, campus, name, is_active) values
    ('NYCU', v_campus, 'PCI測試地點', true)
  on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  insert into auth.users (id, email) values
    (v_a_owner, 'pci_a@nycu.edu.tw'),
    (v_b_owner, 'pci_b@nycu.edu.tw'),
    (v_stranger, 'pci_stranger@nycu.edu.tw');

  insert into app_user (id, email, school, display_name, avatar_url, degree_level, department, contact_line) values
    (v_a_owner, 'pci_a@nycu.edu.tw', 'NYCU', 'PCI Owner A', 'https://avatar.pci_a', 'MASTER', '資工', 'pci_a_line'),
    (v_b_owner, 'pci_b@nycu.edu.tw', 'NYCU', 'PCI Owner B', 'https://avatar.pci_b', 'PHD', '應數', 'pci_b_line'),
    (v_stranger, 'pci_stranger@nycu.edu.tw', 'NYCU', 'PCI Stranger', 'https://avatar.pci_stranger', 'MASTER', null, 'pci_stranger_line');

  insert into activity (activity_type_id, start_time, estimated_end_time, status, school, campus)
  values (v_act_type_id, v_now - interval '1 day', v_now - interval '23 hours', 'COMPLETED', 'NYCU', v_campus)
  returning id into v_past_activity_id;
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_b_owner, v_past_activity_id, 'ATTENDED');

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_a_owner, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 2, 'PENDING_CONFIRMATION')
  returning * into v_req_a;

  insert into match_request (owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status)
  values (v_b_owner, v_act_type_id, 'NYCU', v_campus, v_now, v_now + interval '2 hours', 2, 2, 'PENDING_CONFIRMATION')
  returning * into v_req_b;

  insert into pending_confirmation (request_a_id, request_b_id, confirm_window_expire_at)
  values (v_req_a.id, v_req_b.id, now() + interval '10 minutes')
  returning * into v_pc;

  update fixtures set a_owner_id = v_a_owner, b_owner_id = v_b_owner, stranger_id = v_stranger, pc_id = v_pc.id;
end;
$setup$;

grant select on fixtures to authenticated;

set local role authenticated;

-- -----------------------------------------------------------------------------
-- 1. Party A sees party B's info (not their own)
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select a_owner_id::text from fixtures), true);
end $$;

select is(
  (get_pending_confirmation_candidate_info((select pc_id from fixtures)))->>'display_name',
  'PCI Owner B',
  'party A 應看到 party B 的 display_name（不是自己的）'
);

select is(
  (get_pending_confirmation_candidate_info((select pc_id from fixtures)))->>'degree_level',
  'PHD',
  'party A 應看到 party B 的 degree_level'
);

select is(
  ((get_pending_confirmation_candidate_info((select pc_id from fixtures)))->>'completed_activity_count')::int,
  1,
  'party A 應看到 party B 真實的 completed_activity_count（1，來自真的 ATTENDED 事件，不是 stub）'
);

-- -----------------------------------------------------------------------------
-- 2. Symmetric — party B sees party A's info, with A's (zero) count
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select b_owner_id::text from fixtures), true);
end $$;

select is(
  (get_pending_confirmation_candidate_info((select pc_id from fixtures)))->>'display_name',
  'PCI Owner A',
  'party B 應看到 party A 的 display_name（對稱）'
);

select is(
  ((get_pending_confirmation_candidate_info((select pc_id from fixtures)))->>'completed_activity_count')::int,
  0,
  'party B 看到的 party A completed_activity_count 應為 0（A 沒有任何 ATTENDED 事件）'
);

-- -----------------------------------------------------------------------------
-- 3. 不歸因原則不受影響 — response 明細絕對不在回傳的 keys 裡
-- -----------------------------------------------------------------------------

select ok(
  not (get_pending_confirmation_candidate_info((select pc_id from fixtures)) ? 'user_a_response'),
  '回傳不應包含 user_a_response（不歸因原則，跟 4.1 get_pending_confirmation_status 同一保證）'
);

select ok(
  not (get_pending_confirmation_candidate_info((select pc_id from fixtures)) ? 'user_b_response'),
  '回傳不應包含 user_b_response'
);

-- -----------------------------------------------------------------------------
-- 4. 非當事人 → FORBIDDEN
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select stranger_id::text from fixtures), true);
end $$;

select throws_matching(
  format('select get_pending_confirmation_candidate_info(%L::uuid)', (select pc_id from fixtures)),
  'FORBIDDEN',
  '非當事人（陌生人）呼叫應回 FORBIDDEN'
);

-- -----------------------------------------------------------------------------
-- 5. 不存在的 pending_confirmation_id → NOT_FOUND
-- -----------------------------------------------------------------------------

do $$ begin
  perform set_config('request.jwt.claim.sub', (select a_owner_id::text from fixtures), true);
end $$;

select throws_matching(
  'select get_pending_confirmation_candidate_info(gen_random_uuid())',
  'NOT_FOUND',
  '不存在的 pending_confirmation_id 應回 NOT_FOUND'
);

reset role;

select * from finish();

rollback;
