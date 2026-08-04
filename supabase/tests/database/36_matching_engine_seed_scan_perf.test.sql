-- =============================================================================
-- pgTAP Test — fn_run_matching_engine() 單一大 group 的 seed 選取效能（v1.36-ish）
--
-- 20260804000000_matching_engine_seed_scan_perf.sql 把 seed_loop 的
-- `not (id = any(v_tried_seed_ids))` 陣列排除法換成 keyset pagination，修掉
-- 單一 (activity_type, school, campus) group 塞爆時的 O(n^2)（QA load test 量到
-- 3000 筆同 group 從 9.08s 降到 <1s，見該遷移檔頭註解）。
--
-- 這裡刻意構造「3000 筆同 group、兩兩都配得成」的情境（跟 QA repro 一致），驗證
-- 修好之後不只「不逾時」，而是快很多；同時驗證正確性——都 min=max=2，理論上應該
-- 精確配成 1500 對，沒有任何一筆被漏掉或重複處理。
--
-- 跟 20_matching_engine_scan_budget.test.sql 的差異：那個測的是「永遠配不成」
-- 逼出 scan budget 保護；這個測的是「大量都配得成」的正常情境下 seed 選取本身
-- 是否還會退化成 O(n^2)。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(3);

-- -----------------------------------------------------------------------------
-- 0. Setup：3000 筆同群組（campus = 'SeedPerf測試區'）、min=max=2 的 REQUESTING
--    Request，兩兩互相相容，理論上應精確配成 1500 對
-- -----------------------------------------------------------------------------

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := 'SeedPerf測試區';
  v_now         timestamptz := now();
  v_user_id     uuid;
  v_req_id      uuid;
  i             int;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, 'SeedPerf測試地點', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  for i in 1..3000 loop
    v_user_id := gen_random_uuid();

    insert into auth.users (id, email) values (v_user_id, 'seedperf_' || i || '@nycu.edu.tw');

    insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line)
    values (
      v_user_id, 'seedperf_' || i || '@nycu.edu.tw', 'NYCU', 'SeedPerf User ' || i,
      'https://avatar.example/seedperf_' || i, 'MASTER', 'seedperf_line_' || i
    );

    v_req_id := gen_random_uuid();
    insert into match_request (
      id, owner_id, activity_type_id, school, campus,
      earliest_start, latest_start, min_participants, max_participants, status
    ) values (
      v_req_id, v_user_id, v_act_type_id, 'NYCU', v_campus,
      v_now, v_now + interval '2 hours', 2, 2, 'REQUESTING'
    );

    -- create_request RPC 平常會自動幫 owner 插這筆 request_member；這裡繞過 RPC
    -- 直接寫 match_request，必須手動補上，否則 v_accum_count 永遠是 0，配不成
    -- 任何一組（這是 QA session 自己踩過的 fixture 坑，記錄在 SPEC/QA 筆記裡）。
    insert into request_member (request_id, user_id, role, status)
    values (v_req_id, v_user_id, 'OWNER', 'JOINED');
  end loop;
end;
$setup$;

select is(
  (select count(*)::int from match_request where campus = 'SeedPerf測試區'),
  3000,
  '效能測試 fixture：3000 筆同群組 REQUESTING Request 已就緒'
);

-- -----------------------------------------------------------------------------
-- 1. 執行 fn_run_matching_engine()，量測耗時——修好前這個情境要 9 秒以上，
--    修好後應該遠低於 3 秒（本機實測 ~0.7s，門檻抓寬一點容忍 CI 機器較慢）
-- -----------------------------------------------------------------------------

create temp table seed_perf_run_result (match_count int, elapsed_ms numeric);

do $run$
declare
  v_start        timestamptz;
  v_elapsed_ms   numeric;
  v_match_count  int;
begin
  v_start := clock_timestamp();
  v_match_count := fn_run_matching_engine();
  v_elapsed_ms := extract(epoch from (clock_timestamp() - v_start)) * 1000;

  insert into seed_perf_run_result values (v_match_count, v_elapsed_ms);
end;
$run$;

select ok(
  (select elapsed_ms from seed_perf_run_result) < 3000,
  format(
    '3000 筆同群組、兩兩配得成的 Request 應遠快於修好前的 9 秒（實際耗時 %s ms，門檻 3000 ms）',
    (select elapsed_ms::int from seed_perf_run_result)
  )
);

-- -----------------------------------------------------------------------------
-- 2. 正確性：keyset pagination 換掉陣列排除法後，仍應精確配成 1500 對，
--    不多不少（沒有 seed 被跳過，也沒有重複配對）
-- -----------------------------------------------------------------------------

select is(
  (select match_count from seed_perf_run_result),
  1500,
  '3000 筆 min=max=2、兩兩相容的 Request 應精確配成 1500 對'
);

select finish();
rollback;
