-- =============================================================================
-- Matching Engine 加入 user_block 檢查（v1.17）
-- create or replace fn_run_matching_engine（20260724123000_matching_engine_nway.sql
-- 的完整版本），僅新增一段獨立的 user_block 檢查，其餘邏輯逐行照搬不動。
--
-- 獨立於 match_history_avoidance 檢查（不共用程式碼，語意不同）：
-- user_block 沒有 avoidance 表的正規化 pair 設計（user_a_id < user_b_id），因為
-- 封鎖是有方向性的（誰封鎖誰有語意差異，且可單方解除，不像 avoidance 是系統雙向
-- 對稱寫入）——所以這裡要用 or 比對兩個方向，而不是 least/greatest 正規化成單一
-- 查詢路徑。
-- =============================================================================

create or replace function fn_run_matching_engine()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group           record;
  v_seed            match_request;
  v_tried_seed_ids  uuid[];
  v_candidate       record;
  v_accum_ids       uuid[];
  v_accum_owner_ids uuid[];
  v_accum_count     int;
  v_accum_earliest  timestamptz;
  v_accum_latest    timestamptz;
  v_new_earliest    timestamptz;
  v_new_latest      timestamptz;
  v_cand_count      int;
  v_match_count     int := 0;
begin
  for v_group in (
    select distinct activity_type_id, school, campus
      from match_request
     where status = 'REQUESTING'
  ) loop
    v_tried_seed_ids := array[]::uuid[];

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

      exit when v_seed.id is null;

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
    end loop;
  end loop;

  return v_match_count;
end;
$$;
