-- =============================================================================
-- Migration: 20260928160000_anon_public_campus_demands.sql
-- 
-- 實作未登入訪客「先看活動，再登入加入」之粗粒度、唯讀探索介面
-- 1. anon_rate_limit_bucket：匿名查詢頻率限制中介表（防止 IP 反覆掃描反推行蹤）
-- 2. get_public_campus_demands(p_school, p_campus)：
--    - 嚴格唯讀 SECURITY DEFINER，search_path = public
--    - 時間粗化（date_bin 30分鐘間隔）
--    - 屬性去識別化（完全剔除個人ID、照片、聯絡方式、細分評分與自由填寫科目）
--    - 小樣本抑制（k-anonymity, k >= 2）：等待人數 < 2 不單獨公開展示，防範定位單一個人
--    - 區分「正在等待人數／組數」與「今日已成團人數／組數」
--    - 回傳校區清單與 has_suppressed_demands 標記
--    - 權限：revoke from public, grant to anon, authenticated
-- =============================================================================

create table if not exists public.anon_rate_limit_bucket (
  ip_hash      text not null,
  window_start timestamptz not null,
  request_count int not null default 1,
  primary key (ip_hash, window_start)
);

alter table public.anon_rate_limit_bucket enable row level security;
-- 不對外開放任何 direct table grant，僅限 security definer 內部存取
revoke all on public.anon_rate_limit_bucket from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- get_public_campus_demands
-- -----------------------------------------------------------------------------
create or replace function public.get_public_campus_demands(
  p_school school,
  p_campus text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_campus_filter text := nullif(trim(p_campus), '');
  v_campuses jsonb;
  v_demands jsonb;
  v_has_suppressed boolean := false;
  v_client_ip text;
  v_rate_window timestamptz;
  v_query_count int;
begin
  -- 1. 參數合法性檢查
  if p_school is null then
    raise exception using message = 'INVALID_SCHOOL';
  end if;

  if v_campus_filter is not null and length(v_campus_filter) > 50 then
    raise exception using message = 'INVALID_CAMPUS';
  end if;

  -- 2. 匿名查詢頻率限制（每 IP 每分鐘上限 60 次）
  begin
    v_client_ip := nullif(current_setting('request.headers', true)::json->>'cf-connecting-ip', '');
    if v_client_ip is null then
      v_client_ip := nullif(current_setting('request.headers', true)::json->>'x-forwarded-for', '');
      if v_client_ip is not null then
        v_client_ip := split_part(v_client_ip, ',', 1);
      end if;
    end if;
  exception when others then
    v_client_ip := null;
  end;

  if v_client_ip is not null then
    v_rate_window := date_trunc('minute', now());
    -- 清理過期計數（維持表尺寸精簡）
    delete from public.anon_rate_limit_bucket where window_start < now() - interval '5 minutes';

    insert into public.anon_rate_limit_bucket (ip_hash, window_start, request_count)
    values (md5(v_client_ip), v_rate_window, 1)
    on conflict (ip_hash, window_start)
    do update set request_count = public.anon_rate_limit_bucket.request_count + 1
    returning request_count into v_query_count;

    if v_query_count > 60 then
      raise exception using message = 'RATE_LIMIT_EXCEEDED';
    end if;
  end if;

  -- 3. 取得該校已核准地點之校區清單（依地點多寡排序，主校區在前）
  select coalesce(jsonb_agg(c.campus_name order by c.loc_count desc, c.campus_name asc), '[]'::jsonb)
    into v_campuses
    from (
      select campus as campus_name, count(*) as loc_count
      from location
      where school = p_school and status = 'APPROVED'
      group by campus
    ) c;

  -- 4. 聚合有效未過期的 match_request（時間粗化至 30 分鐘，屬性泛化）
  with raw_demands as (
    select
      mr.activity_type_id,
      at.name as activity_type_name,
      mr.campus,
      -- 時間粗化：30 分鐘為基準單位，去除秒與零碎分鐘
      date_bin(interval '30 minutes', mr.earliest_start, timestamptz '2000-01-01 00:00:00Z') as coarse_earliest_start,
      date_bin(interval '30 minutes', mr.latest_start, timestamptz '2000-01-01 00:00:00Z') as coarse_latest_start,
      mr.sport_level,
      mr.min_participants::int as min_participants,
      mr.max_participants::int as max_participants,
      count(distinct rm.user_id)::int as waiting_person_count,
      count(distinct mr.id)::int as waiting_request_count
    from match_request mr
    join activity_type at on at.id = mr.activity_type_id
    join request_member rm on rm.request_id = mr.id and rm.status = 'JOINED'
    where mr.status = 'REQUESTING'
      and mr.latest_start > now()
      and mr.school = p_school
      and (v_campus_filter is null or mr.campus = v_campus_filter)
    group by
      mr.activity_type_id,
      at.name,
      mr.campus,
      coarse_earliest_start,
      coarse_latest_start,
      mr.sport_level,
      mr.min_participants,
      mr.max_participants
  ),
  formed_stats as (
    -- 今日已成團統計（MATCHED, ONGOING, COMPLETED）
    select
      a.activity_type_id,
      a.campus,
      count(distinct a.id)::int as formed_group_count,
      count(distinct am.user_id)::int as formed_person_count
    from activity a
    join activity_member am on am.activity_id = a.id and am.status = 'JOINED'
    where a.school = p_school
      and (v_campus_filter is null or a.campus = v_campus_filter)
      and a.status in ('MATCHED', 'ONGOING', 'COMPLETED')
      and a.start_time >= date_trunc('day', now())
      and a.start_time < date_trunc('day', now()) + interval '1 day'
    group by a.activity_type_id, a.campus
  ),
  filtered_demands as (
    select
      rd.activity_type_id,
      rd.activity_type_name,
      rd.campus,
      rd.coarse_earliest_start,
      rd.coarse_latest_start,
      rd.sport_level,
      rd.min_participants,
      rd.max_participants,
      rd.waiting_person_count,
      rd.waiting_request_count,
      coalesce(fs.formed_group_count, 0) as formed_group_count,
      coalesce(fs.formed_person_count, 0) as formed_person_count
    from raw_demands rd
    left join formed_stats fs
      on fs.activity_type_id = rd.activity_type_id
     and fs.campus = rd.campus
    -- 小樣本抑制門檻：等待人數 >= 2
    where rd.waiting_person_count >= 2
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'activity_type_id', fd.activity_type_id,
          'activity_type_name', fd.activity_type_name,
          'campus', fd.campus,
          'earliest_start', fd.coarse_earliest_start,
          'latest_start', fd.coarse_latest_start,
          'sport_level', fd.sport_level,
          'min_participants', fd.min_participants,
          'max_participants', fd.max_participants,
          'waiting_person_count', fd.waiting_person_count,
          'waiting_request_count', fd.waiting_request_count,
          'formed_group_count', fd.formed_group_count,
          'formed_person_count', fd.formed_person_count
        )
        order by fd.coarse_earliest_start asc, fd.waiting_person_count desc
      ),
      '[]'::jsonb
    ),
    exists (
      select 1 from raw_demands where waiting_person_count < 2
    )
  into v_demands, v_has_suppressed
  from filtered_demands fd;

  return jsonb_build_object(
    'demands', coalesce(v_demands, '[]'::jsonb),
    'campuses', v_campuses,
    'has_suppressed_demands', coalesce(v_has_suppressed, false)
  );
end;
$$;

-- 權限設置：不公開給 public，僅授權 anon 與 authenticated
revoke execute on function public.get_public_campus_demands(school, text) from public;
grant execute on function public.get_public_campus_demands(school, text) to anon, authenticated;
