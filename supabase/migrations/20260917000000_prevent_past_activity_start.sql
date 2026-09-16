-- =============================================================================
-- 修正成團開始時間：防止活動成立時已經處於「過去時間」（v1.44）
--
-- 說明：
--   現有成團函式 fn_create_activity_from_requests 原先僅使用
--   max(earliest_start) 作為活動開始時間。若媒合成立時，當前時間已晚於
--   該 earliest_start（例如使用卡片一鍵加入或媒合排程延後執行），活動成立時
--   其 start_time 即可能已經開始。
--
-- 修法：
--   1. 在取 max(earliest_start) 後，使用 v_start_time := greatest(v_start_time, now());
--      將開始時間推進至當前時間（若當前時間較晚）。
--   2. 隨後檢查 v_start_time > v_latest_min；若當前時間已超過共同容許時間窗，
--      拋出 NO_COMMON_TIME_WINDOW 防止成立無效活動。
-- =============================================================================

create or replace function fn_create_activity_from_requests(
  p_request_ids uuid[]
)
returns activity
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity_type_id uuid;
  v_school           school;
  v_campus           text;
  v_start_time       timestamptz;
  v_latest_min       timestamptz;
  v_dur              int;
  v_activity         activity;
  v_found_count      int;
  v_bad_status_count int;
begin
  if p_request_ids is null or array_length(p_request_ids, 1) < 2 then
    raise exception using message = 'INVALID_INPUT', detail = 'AT_LEAST_TWO_REQUESTS_REQUIRED';
  end if;

  -- 鎖定全部涉及的 Request，原子處理
  perform 1 from match_request where id = any(p_request_ids) for update;

  select count(*) into v_found_count from match_request where id = any(p_request_ids);
  if v_found_count <> array_length(p_request_ids, 1) then
    raise exception using message = 'NOT_FOUND', detail = 'REQUEST_NOT_FOUND';
  end if;

  select count(*) into v_bad_status_count
    from match_request
   where id = any(p_request_ids)
     and status not in ('REQUESTING', 'PENDING_CONFIRMATION');
  if v_bad_status_count > 0 then
    raise exception using message = 'REQUEST_NOT_OPEN', detail = 'REQUEST_ALREADY_PROCESSED';
  end if;

  select activity_type_id, school, campus, max(earliest_start), min(latest_start)
    into v_activity_type_id, v_school, v_campus, v_start_time, v_latest_min
    from match_request
   where id = any(p_request_ids)
   group by activity_type_id, school, campus;

  -- 防禦性推進：若目前時間已晚於原先計算的 start_time，但仍在共同最新容許時間內，
  -- 應推進到當前時間，避免活動成立時就已經處於「已開始」或「過去時間」的狀態
  v_start_time := greatest(v_start_time, now());

  if v_start_time > v_latest_min then
    -- 理論上呼叫端（fn_run_matching_engine 的 N 方交集檢查）已保證這裡恆成立，
    -- 這只是防禦性檢查，避免未來有新呼叫路徑繞過交集驗證，或當前時間已超過共同時間窗
    raise exception using message = 'INTERNAL_ERROR', detail = 'NO_COMMON_TIME_WINDOW';
  end if;

  select coalesce(default_duration_minutes, 60) into v_dur
    from activity_type where id = v_activity_type_id;

  insert into activity (
    activity_type_id, school, campus, start_time, estimated_end_time,
    status, contact_visible_until
  ) values (
    v_activity_type_id, v_school, v_campus,
    v_start_time, v_start_time + (v_dur || ' minutes')::interval,
    'MATCHED', now() + interval '24 hours'
  )
  returning * into v_activity;

  insert into activity_member (activity_id, user_id, source_request_id, status)
  select v_activity.id, rm.user_id, rm.request_id, 'JOINED'
    from request_member rm
   where rm.request_id = any(p_request_ids) and rm.status = 'JOINED';

  update match_request set status = 'MATCHED' where id = any(p_request_ids);

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MATCH_SUCCESS', jsonb_build_object('activity_id', v_activity.id)
    from activity_member am where am.activity_id = v_activity.id;

  return v_activity;
end;
$$;

revoke execute on function fn_create_activity_from_requests(uuid[]) from public, anon, authenticated;
