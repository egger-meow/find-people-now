-- =============================================================================
-- 活動開始前提前提醒：app_config 多時間點參數 + fn_remind_upcoming_activities()
--
-- 「提前多久提醒」不是單一數值（例如同時要 30 分鐘前 + 10 分鐘前各提醒一次），
-- 跟現有 app_config 其餘 key 都是單一數值（cooldown_minutes、confirm_window_minutes、
-- downgrade_consent_window_minutes、location_reminder_lead_minutes）不同。
--
-- 存法：value 直接存成 Postgres array literal 文字 '{30,10}'，讀取端用
-- fn_get_config_int_array() 做 value::int[] 一行轉型——跟既有 fn_get_config_interval
-- 的 value::interval 寫法完全對稱，是同一套「value 欄位存文字、讀取端依語意 cast」
-- 慣例的自然延伸，不需要 string_to_array 或 jsonb 解析這些額外步驟。
-- =============================================================================

insert into app_config (key, value, description) values
  ('activity_reminder_lead_minutes_list', '{30,10}',
    '活動開始前提前提醒的時間點清單，分鐘，Postgres array literal（fn_get_config_int_array 讀取）；每個時間點各自獨立判斷、觸發一次 ACTIVITY_UPCOMING 通知，fn_remind_upcoming_activities() 使用');

-- 讀取並轉型為 int[] 的共用小工具，對稱 fn_get_config_interval 的既有寫法
create or replace function fn_get_config_int_array(p_key text)
returns int[]
language sql
stable
set search_path = public
as $$
  select value::int[] from app_config where key = p_key;
$$;

-- -----------------------------------------------------------------------------
-- fn_remind_upcoming_activities (新，首次實作)：對應 API.md §9「活動開始前提前
-- 提醒」，發送新事件 ACTIVITY_UPCOMING（跟「已經開始」的 ACTIVITY_REMINDER 區分）
--
-- 掃描 status='MATCHED' 且 start_time 尚未到、但落在任一個設定時間點內的 Activity。
-- 對每個設定的 lead_minutes 值分別掃描、分別去重——去重比照
-- fn_remind_missing_location_candidates 的既有模式（查 notification 表本身有沒有
-- 為同一個 activity「同一個提醒時間點」發過，不額外存欄位），差別只在於這裡的
-- 去重鍵是 (activity_id, lead_minutes) 這一組，而不是單純 activity_id，因為同一個
-- 活動的 30 分鐘提醒與 10 分鐘提醒是兩則不同的通知，各自都要能單獨觸發、單獨去重。
--
-- payload 帶 lead_minutes，前端依這個數字動態組文案（見 docs/API.md §9 文案表）。
-- -----------------------------------------------------------------------------

create or replace function fn_remind_upcoming_activities()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead_list int[];
  v_lead      int;
  v_activity  record;
  v_count     int := 0;
begin
  select fn_get_config_int_array('activity_reminder_lead_minutes_list') into v_lead_list;

  foreach v_lead in array v_lead_list loop
    for v_activity in (
      select a.* from activity a
       where a.status = 'MATCHED'
         and a.start_time > now()
         and a.start_time <= now() + (v_lead || ' minutes')::interval
         and not exists (
           select 1 from notification n
            where n.event_type = 'ACTIVITY_UPCOMING'
              and (n.payload->>'activity_id')::uuid = a.id
              and (n.payload->>'lead_minutes')::int = v_lead
         )
    ) loop
      insert into notification (user_id, event_type, payload)
      select am.user_id, 'ACTIVITY_UPCOMING',
             jsonb_build_object(
               'activity_id', v_activity.id, 'lead_minutes', v_lead, 'start_time', v_activity.start_time
             )
        from activity_member am where am.activity_id = v_activity.id and am.status = 'JOINED';

      v_count := v_count + 1;
    end loop;
  end loop;

  return v_count;
end;
$$;
