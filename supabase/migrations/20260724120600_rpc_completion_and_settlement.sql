-- =============================================================================
-- Phase 7 RPCs — Completion Settlement & Rematch Voting
-- 派生自 docs/SPEC.md §10、§12 及 docs/API.md §7
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: submit_completion_report
-- 提交活動完成回報與多數決自動結算 (A3)
-- -----------------------------------------------------------------------------

create or replace function submit_completion_report(
  p_activity_id     uuid,
  p_result          completion_result,
  p_absent_user_ids uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_total_members int;
  v_report_count  int;
  v_quorum        int;
  v_rec           record;
  v_no_show_cnt   int;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using errcode = 'NOT_ACTIVITY_MEMBER', message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 寫入回報 (DB UNIQUE (activity_id, reporter_id) 防重複)
  begin
    insert into completion_report (activity_id, reporter_id, result, absent_user_ids)
    values (p_activity_id, v_user_id, p_result, coalesce(p_absent_user_ids, '{}'));
  exception when unique_violation then
    raise exception using errcode = 'ALREADY_REPORTED', message = 'ALREADY_REPORTED';
  end;

  -- 計算成員總數與目前回報數
  select count(*) into v_total_members
    from activity_member
   where activity_id = p_activity_id and status = 'JOINED';

  select count(*) into v_report_count
    from completion_report
   where activity_id = p_activity_id;

  -- 多數決法定人數門檻 (>= 50% 參與者)
  v_quorum := ceil(v_total_members::numeric / 2.0);

  if v_report_count >= v_quorum then
    -- 結算處理：遍歷所有成員
    for v_rec in (
      select user_id from activity_member where activity_id = p_activity_id and status = 'JOINED'
    ) loop
      -- 統計指認該 member 缺席的次數
      select count(*) into v_no_show_cnt
        from completion_report cr, unnest(cr.absent_user_ids) uid
       where cr.activity_id = p_activity_id
         and uid = v_rec.user_id;

      -- 2 人互咬特例與多數決判定 (SPEC §10)
      if v_total_members = 2 and v_report_count = 2 and v_no_show_cnt = 1 then
        -- 2 人互相指認缺席 → 不判定 No-show，不記事件
        null;
      elsif v_no_show_cnt >= v_quorum then
        -- 被半數以上指認 → 記 NO_SHOW
        insert into user_reliability_event (user_id, activity_id, event_type)
        values (v_rec.user_id, p_activity_id, 'NO_SHOW');

        -- 連續 3 次 No-show 檢查 → 停權 7 天 (SPEC §12)
        if (
          select count(*)
            from (
              select event_type from user_reliability_event
               where user_id = v_rec.user_id
               order by created_at desc limit 3
            ) sub
           where sub.event_type = 'NO_SHOW'
        ) = 3 then
          update app_user set suspended_until = now() + interval '7 days' where id = v_rec.user_id;
        end if;
      else
        -- 正常出席 → 記 ATTENDED
        insert into user_reliability_event (user_id, activity_id, event_type)
        values (v_rec.user_id, p_activity_id, 'ATTENDED');
      end if;
    end loop;

    -- 更新 Activity 狀態為 COMPLETED
    update activity set status = 'COMPLETED' where id = p_activity_id;
  end if;

  return jsonb_build_object('success', true, 'settled', (v_report_count >= v_quorum));
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: rematch_vote
-- 再約按鈕 (👍 再約，雙向成立解鎖永久聯絡方式)
-- -----------------------------------------------------------------------------

create or replace function rematch_vote(
  p_activity_id uuid,
  p_to_user_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id   uuid := auth.uid();
  v_is_mutual boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'UNAUTHORIZED', message = 'UNAUTHORIZED';
  end if;

  if v_user_id = p_to_user_id then
    raise exception using errcode = 'INVALID_INPUT', message = 'CANNOT_VOTE_SELF';
  end if;

  -- 檢查雙方是否皆為該活動成員
  if not exists (select 1 from activity_member where activity_id = p_activity_id and user_id = v_user_id) or
     not exists (select 1 from activity_member where activity_id = p_activity_id and user_id = p_to_user_id) then
    raise exception using errcode = 'NOT_ACTIVITY_MEMBER', message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 寫入投票
  insert into rematch_vote (activity_id, from_user_id, to_user_id)
  values (p_activity_id, v_user_id, p_to_user_id)
  on conflict do nothing;

  -- 檢查是否雙向成立
  if exists (
    select 1 from rematch_vote
     where activity_id = p_activity_id and from_user_id = p_to_user_id and to_user_id = v_user_id
  ) then
    v_is_mutual := true;
  end if;

  return jsonb_build_object('success', true, 'is_mutual', v_is_mutual);
end;
$$;
