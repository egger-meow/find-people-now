-- =============================================================================
-- pgTAP Test — fn_run_matching_engine() 候選掃描預算上限（v1.22）
--
-- 20260724125300_matching_engine_scan_budget.sql 幫函式加了每個 (activity_type,
-- school, campus) 群組的候選掃描預算（v_group_scan_budget = 5000），避免群組內
-- 請求數一多、彼此又配不成時退化成 O(N^2) 卡住整個排程。
--
-- 這裡刻意建構「永遠配不成」的最壞情況（500 筆同群組 Request，每筆
-- min_participants = max_participants = 999，任兩筆都不可能湊到 999 人）：
-- 沒有預算保護的舊版會讓外層對每個 seed 都把剩下的候選整個掃過一輪，
-- 500 * 500 = 250,000 次候選檢查；有預算保護後單次執行應該在遠低於此的
-- 掃描次數內就跳到下一個群組返回，驗證的是「不會被卡住」，不是「配對正確性」
-- （正確性已由 15_matching_engine_nway.test.sql 覆蓋）。
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(4);

-- -----------------------------------------------------------------------------
-- 0. Setup：500 筆同群組（campus = '負載測試區'）、彼此永遠配不成的 REQUESTING Request
-- -----------------------------------------------------------------------------

do $setup$
declare
  v_act_type_id uuid;
  v_campus      text := '負載測試區';
  v_now         timestamptz := now();
  v_user_id     uuid;
  i             int;
begin
  select id into v_act_type_id from activity_type where name = '咖啡' limit 1;

  insert into location (school, campus, name, is_active) values ('NYCU', v_campus, '負載測試地點', true)
    on conflict (school, name) do update set is_active = true, campus = excluded.campus;

  for i in 1..500 loop
    v_user_id := gen_random_uuid();

    insert into auth.users (id, email) values (v_user_id, 'load_' || i || '@nycu.edu.tw');

    insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line)
    values (
      v_user_id, 'load_' || i || '@nycu.edu.tw', 'NYCU', 'Load User ' || i,
      'https://avatar.example/load_' || i, 'MASTER', 'load_line_' || i
    );

    -- min=max=999：跟任何其他一筆（甚至任意子集）都不可能湊到 999 人，
    -- 保證這個群組在整個測試期間永遠配不成，逼出最壞情況的掃描量
    insert into match_request (
      owner_id, activity_type_id, school, campus,
      earliest_start, latest_start, min_participants, max_participants, status
    ) values (
      v_user_id, v_act_type_id, 'NYCU', v_campus,
      v_now, v_now + interval '2 hours', 999, 999, 'REQUESTING'
    );
  end loop;
end;
$setup$;

select is(
  (select count(*)::int from match_request where campus = '負載測試區'),
  500,
  '負載測試 fixture：500 筆同群組 REQUESTING Request 已就緒'
);

-- -----------------------------------------------------------------------------
-- 1. 執行 fn_run_matching_engine()，量測耗時 + 確認有正常返回（不逾時、不報錯）
-- -----------------------------------------------------------------------------

create temp table run_result (match_count int, elapsed_ms numeric);

do $run$
declare
  v_start        timestamptz;
  v_elapsed_ms   numeric;
  v_match_count  int;
begin
  v_start := clock_timestamp();
  v_match_count := fn_run_matching_engine();
  v_elapsed_ms := extract(epoch from (clock_timestamp() - v_start)) * 1000;

  insert into run_result values (v_match_count, v_elapsed_ms);
end;
$run$;

select ok(
  (select elapsed_ms from run_result) < 10000,
  format(
    '500 筆永遠配不成的同群組 Request 應在預算內快速返回（實際耗時 %s ms，門檻 10000 ms，' ||
    '有預算保護前的 O(N^2) 最壞情況會是這個門檻的數十倍）',
    (select elapsed_ms::int from run_result)
  )
);

select is(
  (select match_count from run_result),
  0,
  '500 筆 min_participants=999 的 Request 不該有任何一組湊到 999 人，match_count 應為 0'
);

-- -----------------------------------------------------------------------------
-- 2. 正確性：預算用完只是「這輪先跳過」，不代表誤判/誤寫入——500 筆應全部仍是
--    REQUESTING（沒有被誤標記成其他狀態），下一輪排程還能繼續嘗試
-- -----------------------------------------------------------------------------

select is(
  (select count(*)::int from match_request where campus = '負載測試區' and status = 'REQUESTING'),
  500,
  '預算用完後 500 筆 Request 應維持 REQUESTING（沒有被誤判成功或誤寫入其他狀態）'
);

select finish();
rollback;
