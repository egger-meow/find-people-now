-- =============================================================================
-- 修補三個「文件寫了、從未真的 raise」的驗證缺口（見 app/lib/rpc/RPC_COVERAGE.md
-- 「Error codes documented in API.md but never raised」一節的校對結果）：
--
-- 1. cancel_activity_participation：完全沒檢查 activity.status，對一個已
--    COMPLETED/CANCELLED 的活動仍可呼叫，會誤記 LATE_CANCEL 事件、觸發冷卻。
--    STATE_MACHINE.md A5/A6 明定這支只該在 MATCHED/ONGOING 觸發 → 補上狀態檢查，
--    重用 6.6/6.7 已經在用的 ACTIVITY_NOT_ACTIVE（同一個「status not in
--    (MATCHED,ONGOING)」條件），不新造一個從未實作過的 ACTIVITY_ALREADY_ENDED。
-- 2. submit_completion_report：完全沒檢查 activity.status，補上「必須是
--    ONGOING」才能提交完成回報（ACTIVITY_NOT_ENDED）。這同時堵上一個潛在 bug：
--    結算迴圈每次達到法定人數門檻就整個重跑一次，COMPLETED 之後若還有新報告
--    插入會重複寫入 user_reliability_event；狀態檢查讓這條路徑不可能再發生。
-- 3. submit_completion_report：absent_user_ids 完全沒驗證是否為活動成員，
--    補上成員資格檢查（INVALID_ABSENT_TARGET）。
--
-- 兩支函式皆 create or replace 自 20260724122600_delete_account_guard.sql 的
-- 最終版本（含 ACCOUNT_DELETED 檢查），只插入本輪新增的檢查，其餘邏輯逐字保留。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. cancel_activity_participation
-- -----------------------------------------------------------------------------
create or replace function cancel_activity_participation(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_activity   activity;
  v_event_type reliability_event_type;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity
    from activity
   where id = p_activity_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- STATE_MACHINE.md A5/A6：只有 MATCHED/ONGOING 才能觸發個別取消；已 COMPLETED/
  -- CANCELLED 的活動不再接受這個轉移，跟 6.6/6.7 的 ACTIVITY_NOT_ACTIVE 同一個閘門
  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  -- 依時間點判定懲罰分級 (SPEC §10)：開始前 >= 1h 為 EARLY_CANCEL，否則為 LATE_CANCEL
  if now() < v_activity.start_time - interval '1 hour' then
    v_event_type := 'EARLY_CANCEL';
  else
    v_event_type := 'LATE_CANCEL';
  end if;

  -- 寫入 Reliability 事件
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_user_id, p_activity_id, v_event_type);

  -- LATE_CANCEL 觸發冷卻 (v1.7，SPEC §6.3；冷卻時長來自 app_config.cooldown_minutes)；EARLY_CANCEL 屬正常改行程，不觸發
  if v_event_type = 'LATE_CANCEL' then
    update app_user set next_request_allowed_at = now() + fn_get_config_interval('cooldown_minutes') where id = v_user_id;
  end if;

  -- 更新成員狀態
  update activity_member
     set status = 'CANCELLED'
   where activity_id = p_activity_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'event_type', v_event_type);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. submit_completion_report
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
  v_user_id        uuid := auth.uid();
  v_activity_status activity_status;
  v_total_members  int;
  v_report_count   int;
  v_quorum         int;
  v_rec            record;
  v_no_show_cnt    int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select status into v_activity_status from activity where id = p_activity_id;

  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 完成回報只該在活動實際進行中（ONGOING）提交：MATCHED 代表還沒開始，
  -- COMPLETED/CANCELLED 代表已經結算過或活動本身取消了，都不該再接受新回報
  -- （後者順便堵住一個潛在 bug：結算迴圈每次達到法定人數門檻就整個重跑一次，
  -- COMPLETED 之後若還有新報告插入會重複寫入 user_reliability_event）
  if v_activity_status <> 'ONGOING' then
    raise exception using message = 'ACTIVITY_NOT_ENDED';
  end if;

  -- 指認對象必須限定在該活動的成員名單內 (SPEC §10)
  if p_absent_user_ids is not null and array_length(p_absent_user_ids, 1) > 0 then
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

  -- 寫入回報 (DB UNIQUE (activity_id, reporter_id) 防重複)
  begin
    insert into completion_report (activity_id, reporter_id, result, absent_user_ids)
    values (p_activity_id, v_user_id, p_result, coalesce(p_absent_user_ids, '{}'));
  exception when unique_violation then
    raise exception using message = 'ALREADY_REPORTED';
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
