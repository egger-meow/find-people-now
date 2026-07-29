-- =============================================================================
-- fn_run_matching_engine() 加上單次執行的候選掃描預算上限（防禦性修補）
--
-- 根因：外層對每個 (activity_type, school, campus) 群組，逐一挑 seed，內層
-- 每次重新掃一次同群組所有 REQUESTING 候選（20260724124300_matching_engine_
-- user_block_check.sql:34-147 逐行照搬 20260724123000_matching_engine_nway.sql
-- 的結構，本檔不改動比對邏輯本身）。當一個群組內請求數到幾百筆、且候選彼此都配
-- 不成（例如人數區間互斥、時間窗不交集），最壞情況下每個 seed 都會把整個群組的
-- 候選掃過一輪一次都配不成——退化成 O(N^2)，單次執行時間隨群組大小平方成長。
--
-- 這支函式目前規劃掛 pg_cron 每 30-60 秒跑一次（見 20260724125400_
-- schedule_background_jobs.sql）；如果單一群組的異常資料量把單次執行時間拖到
-- 超過排程間隔，會跟下一輪排程重疊（該檔另外用 advisory lock 擋重疊執行，但
-- 重疊本身已經代表這一輪沒有在預期時間內結束，是問題本身，不是加鎖就解決）。
--
-- 修法：幫每個群組加一個「候選掃描次數」預算（v_group_scan_budget），逐一累加
-- 內層 for 迴圈每次檢查一個候選的次數；一旦某個群組用完預算，直接跳到下一個
-- 群組，本群組還沒試過的 seed 留到下一輪排程（30-60 秒後）繼續——不影響其他
-- 群組，也不會讓任何 Request 卡住不被處理，只是大群組可能要跨好幾輪排程才處理
-- 完，這是可接受的降級，不是正確性問題（見 20260724123000 檔頭「不變量③」：
-- 沒配成不會被誤判為已處理，維持 REQUESTING 留給下一輪）。
--
-- 預算值 5000：單次候選檢查只有幾個索引查詢 + 陣列比對，數量級是毫秒等級；
-- 5000 次留了充足的餘裕（MVP 現況單一 (activity_type, school, campus) 群組
-- 內的 REQUESTING 筆數遠低於能讓 5000 次檢查跑到秒等級的規模），之後若真的
-- 跑出效能問題，先看 pgTAP 15_matching_engine_nway.test.sql /
-- 20_matching_engine_scan_budget.test.sql 的 500 筆負載測試實際跑多久，再決定
-- 要調預算或改演算法，不用先猜。
-- =============================================================================

create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group              record;
  v_seed                match_request;
  v_tried_seed_ids      uuid[];
  v_candidate           record;
  v_accum_ids           uuid[];
  v_accum_owner_ids     uuid[];
  v_accum_count         int;
  v_accum_earliest      timestamptz;
  v_accum_latest        timestamptz;
  v_new_earliest        timestamptz;
  v_new_latest          timestamptz;
  v_cand_count          int;
  v_match_count         int := 0;
  v_group_scan_budget   constant int := 5000;
  v_group_scans_used    int;
begin
  <<group_loop>>
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    v_tried_seed_ids := array[]::uuid[];
    v_group_scans_used := 0;

    <<seed_loop>>
    loop
      -- live 重新挑「目前仍是 REQUESTING、本次執行還沒試過」中 created_at 最早的一筆
      -- 當種子——用全新 select（非 for-loop cursor）避免舊版的 snapshot 過期問題
      select * into v_seed
        from match_request
       where activity_type_id = v_group.activity_type_id
         and school = v_group.school
         and campus = v_group.campus
         and status = 'REQUESTING'
         and not (id = any(v_tried_seed_ids))
       order by created_at asc
       limit 1;

      exit seed_loop when v_seed.id is null;

      v_tried_seed_ids := v_tried_seed_ids || v_seed.id;

      select count(*) into v_accum_count
        from request_member where request_id = v_seed.id and status = 'JOINED';

      v_accum_ids := array[v_seed.id];
      v_accum_owner_ids := array[v_seed.owner_id];
      v_accum_earliest := v_seed.earliest_start;
      v_accum_latest := v_seed.latest_start;

      for v_candidate in (
        select r.* from match_request r
         where r.activity_type_id = v_group.activity_type_id
           and r.school = v_group.school
           and r.campus = v_group.campus
           and r.status = 'REQUESTING'
           and r.id <> v_seed.id
           -- ①候選篩選：[候選 min,max] 跟 [種子 min,max] 存在至少一個雙方都能接受的
           -- 人數（null = 不設上限，視為 +∞）。殘留邊界情況見 20260724123000 檔頭說明。
           and (v_seed.max_participants is null or r.min_participants <= v_seed.max_participants)
           and (r.max_participants is null or v_seed.min_participants <= r.max_participants)
         order by r.created_at asc
      ) loop
        exit when v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2;

        v_group_scans_used := v_group_scans_used + 1;

        -- live 重新確認候選目前仍是 REQUESTING（防禦性；本次執行內不會有其他寫入
        -- 打斷同一個候選掃描，但保留這道檢查以防未來維護時引入例外）
        if not exists (select 1 from match_request where id = v_candidate.id and status = 'REQUESTING') then
          continue;
        end if;

        -- N 方時間窗交集：每加入一個候選都重算整體上下界，不是只跟種子比較
        v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
        v_new_latest := least(v_accum_latest, v_candidate.latest_start);
        if v_new_earliest > v_new_latest then
          continue; -- 加入這個候選會讓交集消失，跳過
        end if;

        -- avoidance 檢查：候選 owner 跟目前累積集合裡「每一個」owner 比對
        -- （owner-only，沿用既有 match_history_avoidance 的 pair 正規化慣例）
        if exists (
          select 1
            from unnest(v_accum_owner_ids) as ao(owner_id)
            join match_history_avoidance mha
              on mha.user_a_id = least(ao.owner_id, v_candidate.owner_id)
             and mha.user_b_id = greatest(ao.owner_id, v_candidate.owner_id)
             and mha.expire_at > now()
        ) then
          continue;
        end if;

        -- user_block 檢查（v1.17，獨立於上面的 avoidance 檢查，見檔頭說明）：候選 owner
        -- 跟目前累積集合裡「每一個」owner，任一方向存在 user_block 記錄就跳過。
        if exists (
          select 1
            from unnest(v_accum_owner_ids) as ao(owner_id)
            join user_block ub
              on (ub.blocker_id = ao.owner_id and ub.blocked_id = v_candidate.owner_id)
              or (ub.blocker_id = v_candidate.owner_id and ub.blocked_id = ao.owner_id)
        ) then
          continue;
        end if;

        select count(*) into v_cand_count
          from request_member where request_id = v_candidate.id and status = 'JOINED';

        -- ②：候選整筆併入會超過種子 max_participants 就跳過，繼續看下一個候選
        -- （不整批停止掃描，可能還有更小的候選塞得下）
        if v_seed.max_participants is not null and v_accum_count + v_cand_count > v_seed.max_participants then
          continue;
        end if;

        v_accum_ids := v_accum_ids || v_candidate.id;
        v_accum_owner_ids := v_accum_owner_ids || v_candidate.owner_id;
        v_accum_count := v_accum_count + v_cand_count;
        v_accum_earliest := v_new_earliest;
        v_accum_latest := v_new_latest;
      end loop;

      if v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2 then
        -- 分支判準：實際累積人數（見 20260724123000 檔頭「證明」，<=2 時集合必然剛好 2 筆 Request）
        if v_accum_count > 2 then
          perform fn_create_activity_from_requests(v_accum_ids);
        else
          perform commit_match(v_accum_ids[1], v_accum_ids[2]);
        end if;
        v_match_count := v_match_count + 1;
      end if;
      -- 否則：不做任何狀態變更，種子與所有候選維持 REQUESTING，留到下次執行重試
      -- （不變量③：即使種子已自足也不會單獨成局，見 20260724123000 檔頭說明）

      -- 本群組候選掃描預算用完：結束 seed_loop、讓外層 group_loop 前進到下一個
      -- 群組，本群組剩下沒試過的 seed 留給下一輪排程（30-60 秒後）繼續，不影響
      -- 其他群組這一輪的處理（注意這裡是 exit seed_loop，不是 exit group_loop——
      -- 用完預算只該跳過「這個」群組剩下的 seed，不該連其他群組都不處理了）
      exit seed_loop when v_group_scans_used >= v_group_scan_budget;
    end loop;
  end loop;

  return v_match_count;
end;
$$;
