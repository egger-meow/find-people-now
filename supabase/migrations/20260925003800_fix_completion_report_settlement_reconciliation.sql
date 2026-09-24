-- =============================================================================
-- Migration: 20260925003800_fix_completion_report_settlement_reconciliation.sql
--
-- 解決 P1：部分成員可能永遠無法回報活動（尤其是 2 人場次第一人回報即結算封死第二人）
--
-- 1. 24 小時回報窗口：
--    - 活動即使轉為 COMPLETED，只要在 24 小時回報窗口內
--      (now() <= greatest(contact_visible_until, start_time + 24 hours))，
--      尚未回報過的 JOINED 成員依然可以提交完成回報。
--    - 超過 24 小時窗口後才禁止回報（回 ACTIVITY_NOT_ACTIVE）。
--    - MATCHED（尚未開始）回 ACTIVITY_NOT_ENDED。
--    - CANCELLED 回 ACTIVITY_NOT_ACTIVE。
--
-- 2. 冪等結算與互咬校正（Reconciliation）：
--    - 達法定人數門檻 (>= 50%) 即將活動推進為 COMPLETED（不卡開新團）。
--    - 結算時清理該 activity_id 舊有的 ATTENDED / NO_SHOW 事件並重新依所有現有回報評估。
--    - 2 人互咬特例 (v_total_members = 2 and v_report_count = 2 and v_no_show_cnt = 1)：
--      雙方互相指認缺席時，不判定 No-show，不記事件，並撤銷先前因單方回報誤判的停權。
-- =============================================================================

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
  v_user_id               uuid := auth.uid();
  v_activity_status       activity_status;
  v_start_time            timestamptz;
  v_contact_visible_until timestamptz;
  v_total_members         int;
  v_report_count          int;
  v_quorum                int;
  v_rec                   record;
  v_no_show_cnt           int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select status, start_time, contact_visible_until
    into v_activity_status, v_start_time, v_contact_visible_until
    from activity
   where id = p_activity_id;

  if not found then
    raise exception using message = 'NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 1. 狀態與時間窗口檢查
  if v_activity_status in ('MATCHED', 'CANCELLED') then
    raise exception using message = 'ACTIVITY_NOT_ENDED';
  end if;

  -- 24 小時回報窗口閘門：無論 status 是 ONGOING 還是已達門檻轉為 COMPLETED，
  -- 只要在 24 小時窗口內皆放行回報；超過窗口則禁止
  if now() > greatest(coalesce(v_contact_visible_until, v_start_time + interval '24 hours'), v_start_time + interval '24 hours') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  -- 2. 指認對象必須限定在該活動的成員名單內 (SPEC §10)，且不能指認自己
  if p_absent_user_ids is not null and array_length(p_absent_user_ids, 1) > 0 then
    if v_user_id = any(p_absent_user_ids) then
      raise exception using message = 'INVALID_ABSENT_TARGET';
    end if;

    if exists (
      select 1 from unnest(p_absent_user_ids) as uid
       where not exists (
         select 1 from activity_member
          where activity_id = p_activity_id and user_id = uid and status = 'JOINED'
       )
    ) then
      raise exception using message = 'INVALID_ABSENT_TARGET';
    end if;
  end if;

  -- 3. 寫入回報 (DB UNIQUE (activity_id, reporter_id) 防重複)
  begin
    insert into completion_report (activity_id, reporter_id, result, absent_user_ids)
    values (p_activity_id, v_user_id, p_result, coalesce(p_absent_user_ids, '{}'));
  exception when unique_violation then
    raise exception using message = 'ALREADY_REPORTED';
  end;

  -- 4. 計算成員總數與目前回報數
  select count(*) into v_total_members
    from activity_member
   where activity_id = p_activity_id and status = 'JOINED';

  select count(*) into v_report_count
    from completion_report
   where activity_id = p_activity_id;

  -- 多數決法定人數門檻 (>= 50% 參與者，例如 2 人為 1 人)
  v_quorum := ceil(v_total_members::numeric / 2.0);

  if v_report_count >= v_quorum then
    -- 活動推進為 COMPLETED
    if v_activity_status = 'ONGOING' then
      update activity set status = 'COMPLETED' where id = p_activity_id;
    end if;

    -- 冪等校正：清除先前因結算寫入的 ATTENDED / NO_SHOW 事件（保留 EARLY/LATE_CANCEL）
    delete from user_reliability_event
     where activity_id = p_activity_id
       and event_type in ('ATTENDED', 'NO_SHOW');

    -- 重新依所有已提交之回報結算全體成員
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
        -- 若先前因第一人回報誤判造成停權，即時撤回
        update app_user
           set suspended_until = null
         where id = v_rec.user_id
           and suspended_until > now()
           and (
             select count(*) from (
               select event_type from user_reliability_event
                where user_id = v_rec.user_id
                order by created_at desc limit 3
             ) sub where sub.event_type = 'NO_SHOW'
           ) < 3;
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
  end if;

  return jsonb_build_object('success', true, 'settled', (v_report_count >= v_quorum));
end;
$$;
