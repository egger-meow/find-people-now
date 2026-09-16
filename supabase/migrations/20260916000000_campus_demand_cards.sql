-- =============================================================================
-- 新增 get_campus_demands RPC 與修正 get_campus_pulse 過期需求篩選（v1.43）
--
-- 1. 修正 get_campus_pulse：
--    補上 `mr.latest_start > now()`。先前只過濾 `mr.status = 'REQUESTING'`，
--    在背景過期清理 cron 尚未觸發前，已過期的 Request 仍會被算進人氣，
--    造成前端顯示不實的等待中人數。
--
-- 2. 新增 get_campus_demands(p_school, p_campus)：
--    首頁改版為「匿名活動需求卡」的核心決策資料來源。
--    依 (activity_type_id, at.name, campus, earliest_start, latest_start,
--        sport_level, sport_level_rating, study_target) 聚合有效需求。
--    回傳欄位：
--      - activity_type_id (uuid)
--      - activity_type_name (text)
--      - campus (text)
--      - earliest_start (timestamptz)
--      - latest_start (timestamptz)
--      - sport_level (text)
--      - sport_level_rating (int)
--      - study_target (text)
--      - min_participants (int)
--      - max_participants (int)
--      - person_count (int)  -- 實際加入的人頭數 (count distinct rm.user_id)
--      - request_count (int) -- 需求組數 (count distinct mr.id)
--
-- 盲配隱私邊界：
--    絕不回傳 user_id、頭像、姓名、性別或學歷資訊，僅回傳匿名活動條件與聚合計數。
-- =============================================================================

-- 1. 修正 get_campus_pulse
drop function if exists get_campus_pulse(school, text);

create function get_campus_pulse(
  p_school school,
  p_campus text
)
returns table (
  activity_type_id   uuid,
  activity_type_name text,
  person_count       int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  return query
    select mr.activity_type_id, at.name, count(rm.*)::int
      from match_request mr
      join activity_type at on at.id = mr.activity_type_id
      join request_member rm on rm.request_id = mr.id and rm.status = 'JOINED'
     where mr.status = 'REQUESTING'
       and mr.latest_start > now()
       and mr.school = p_school
       and mr.campus = p_campus
     group by mr.activity_type_id, at.name
     order by count(rm.*) desc;
end;
$$;

-- 2. 新增 get_campus_demands
drop function if exists get_campus_demands(school, text);

create function get_campus_demands(
  p_school school,
  p_campus text
)
returns table (
  activity_type_id   uuid,
  activity_type_name text,
  campus             text,
  earliest_start     timestamptz,
  latest_start       timestamptz,
  sport_level        text,
  sport_level_rating int,
  study_target       text,
  min_participants   int,
  max_participants   int,
  person_count       int,
  request_count      int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  return query
    select
      mr.activity_type_id,
      at.name as activity_type_name,
      mr.campus,
      mr.earliest_start,
      mr.latest_start,
      mr.sport_level,
      mr.sport_level_rating,
      mr.study_target,
      min(mr.min_participants)::int as min_participants,
      max(mr.max_participants)::int as max_participants,
      count(distinct rm.user_id)::int as person_count,
      count(distinct mr.id)::int as request_count
    from match_request mr
    join activity_type at on at.id = mr.activity_type_id
    join request_member rm on rm.request_id = mr.id and rm.status = 'JOINED'
   where mr.status = 'REQUESTING'
     and mr.latest_start > now()
     and mr.school = p_school
     and mr.campus = p_campus
   group by
     mr.activity_type_id,
     at.name,
     mr.campus,
     mr.earliest_start,
     mr.latest_start,
     mr.sport_level,
     mr.sport_level_rating,
     mr.study_target
   order by
     mr.earliest_start asc,
     count(distinct rm.user_id) desc;
end;
$$;

-- 權限配置
grant execute on function get_campus_pulse(school, text) to authenticated;
grant execute on function get_campus_demands(school, text) to authenticated;
