-- =============================================================================
-- fn_run_matching_engine()：修掉單一 group 塞爆時的 O(n^2) seed 選取
--
-- 背景（QA load test, 2026-08-03/04）：3000 筆 REQUESTING Request 集中在同一個
-- (activity_type_id, school, campus) group 時，fn_run_matching_engine() 耗時
-- 9.08s；同樣數量級但分散在 10 個 group（每組最多 120 筆）只要 ~200ms。
-- idx_request_queue 本身健康（EXPLAIN ANALYZE 是 Index Scan，不是 Seq Scan）；
-- 瓶頸在 seed_loop 每輪重新查詢下一個 seed 時用的
-- `not (id = any(v_tried_seed_ids))`：v_tried_seed_ids 每輪成長一個元素，
-- 一個 3000 筆的 group 需要約 1500 輪 seed 迭代才能耗盡，每輪都要對 group 內
-- 剩餘所有列做一次陣列成員檢查——退化成 O(n^2)。
--
-- 修法：seed 永遠照 created_at asc 依序挑選，且一旦被選為 seed 就不會再被選
-- 一次（原本 v_tried_seed_ids 的語意），所以「已試過的 seed」在 created_at 順序
-- 上必然是目前為止已掃過的前綴。用 keyset pagination 取代陣列排除法——只記錄
-- 上一個 seed 的 (created_at, id)，下一輪直接 WHERE (created_at, id) > (上一輪)
-- 撈「下一筆」，讓查詢用得上索引，不用再线性排除整個已試清單。
--
-- 新增 idx_request_queue_seed_order 索引支援這個 keyset 查詢（原本
-- idx_request_queue 是排 latest_start，不是 created_at，撐不起這裡的排序）。
-- candidate loop 原本就是 order by r.created_at asc，也一併受惠。
--
-- 正確性不變：只是換一種方式追蹤「哪些列已經當過 seed」，篩選/配對邏輯完全
-- 照抄 20260803160300_study_target_rpc.sql。
-- =============================================================================

create index if not exists idx_request_queue_seed_order
  on match_request (activity_type_id, school, campus, created_at, id)
  where (status = 'REQUESTING');

create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group               record;
  v_seed                match_request;
  v_has_prev_seed       boolean;
  v_prev_seed_created_at timestamptz;
  v_prev_seed_id        uuid;
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
  if not pg_try_advisory_xact_lock(45001, 1) then
    return 0;
  end if;

  <<group_loop>>
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    v_has_prev_seed := false;
    v_group_scans_used := 0;

    <<seed_loop>>
    loop
      if v_has_prev_seed then
        select * into v_seed
          from match_request
         where activity_type_id = v_group.activity_type_id
           and school = v_group.school
           and campus = v_group.campus
           and status = 'REQUESTING'
           and (created_at, id) > (v_prev_seed_created_at, v_prev_seed_id)
         order by created_at asc, id asc
         limit 1;
      else
        select * into v_seed
          from match_request
         where activity_type_id = v_group.activity_type_id
           and school = v_group.school
           and campus = v_group.campus
           and status = 'REQUESTING'
         order by created_at asc, id asc
         limit 1;
      end if;

      exit seed_loop when v_seed.id is null;

      v_prev_seed_created_at := v_seed.created_at;
      v_prev_seed_id := v_seed.id;
      v_has_prev_seed := true;

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
           -- ②skill_level 相容性（v1.34）：null=wildcard，非 null 只跟相同等級或
           -- 對方是 null 相容，邏輯封裝在 fn_skill_level_match。
           and fn_skill_level_match(v_seed.skill_level, r.skill_level)
           -- ③study_target 相容性（v1.35，僅讀書類型會非 null）：null=wildcard，
           -- 非 null 需正規化後完全相同。比對用 *_normalized 欄位，不影響顯示用
           -- 的原文欄位。
           and (
             v_seed.study_target_normalized is null
             or r.study_target_normalized is null
             or v_seed.study_target_normalized = r.study_target_normalized
           )
         order by r.created_at asc
      ) loop
        exit when v_accum_count >= v_seed.min_participants and array_length(v_accum_ids, 1) >= 2;

        v_group_scans_used := v_group_scans_used + 1;

        if not exists (select 1 from match_request where id = v_candidate.id and status = 'REQUESTING') then
          continue;
        end if;

        v_new_earliest := greatest(v_accum_earliest, v_candidate.earliest_start);
        v_new_latest := least(v_accum_latest, v_candidate.latest_start);
        if v_new_earliest > v_new_latest then
          continue;
        end if;

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
        if v_accum_count > 2 then
          perform fn_create_activity_from_requests(v_accum_ids);
        else
          perform commit_match(v_accum_ids[1], v_accum_ids[2]);
        end if;
        v_match_count := v_match_count + 1;
      end if;

      exit seed_loop when v_group_scans_used >= v_group_scan_budget;
    end loop;
  end loop;

  return v_match_count;
end;
$$;
