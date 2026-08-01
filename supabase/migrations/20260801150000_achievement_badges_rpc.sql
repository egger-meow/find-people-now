-- =============================================================================
-- Achievement Badges — RPC (v1.29)
--
-- 使用者要求「獎勵使用者，而不是強調可信度等級」，同時「補充既有的可信度
-- 系統，不是取代」。刻意不新增任何表／欄位——徽章全部從既有資料
-- （`user_reliability_event`／`rematch_vote`／`match_request`）即時計算，
-- 跟 Reliability 等級本身「不存分數欄位，查詢時算」同一個精神（SPEC v1.1
-- 變更 4）。這支 RPC 純讀取、不寫入任何東西，是這輪風險最低的一支。
--
-- 四個徽章（判準皆為 MVP 起始值，非精算門檻，之後可依實際數據調整，調整
-- 不需要改 schema）：
--   🌱 初次參團：至少 1 次 ATTENDED
--   ⚡ 準時好車友：至少 3 次 ATTENDED 且 0 次 NO_SHOW（累計，不比照
--     fn_reliability_tier 只看近 30 天——徽章代表「曾經達成」的里程碑，不是
--     即時等級，達成後不該因為 30 天沒活動就消失）
--   ☕ 相談甚歡：至少 1 組互相按過「再約」（rematch_vote 雙向成立）
--   🏀 熱血揪團長：自己發起（owner）且成功配對（status='MATCHED'）的
--     Request 達 3 筆
-- =============================================================================

create or replace function get_my_badges()
returns table (
  badge_code text,
  earned     boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_attended     int;
  v_no_show      int;
  v_mutual_count int;
  v_organized    int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select count(*) filter (where event_type = 'ATTENDED'),
         count(*) filter (where event_type = 'NO_SHOW')
    into v_attended, v_no_show
    from user_reliability_event
   where user_id = v_user_id;

  select count(*) into v_mutual_count
    from rematch_vote a
   where a.from_user_id = v_user_id
     and exists (
       select 1 from rematch_vote b
        where b.activity_id = a.activity_id
          and b.from_user_id = a.to_user_id
          and b.to_user_id = v_user_id
     );

  select count(*) into v_organized
    from match_request
   where owner_id = v_user_id and status = 'MATCHED';

  return query
    select 'FIRST_ACTIVITY', v_attended >= 1
    union all
    select 'PUNCTUAL', v_attended >= 3 and v_no_show = 0
    union all
    select 'GREAT_COMPANY', v_mutual_count >= 1
    union all
    select 'ENTHUSIASTIC_ORGANIZER', v_organized >= 3;
end;
$$;
