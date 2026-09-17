-- =============================================================================
-- 最小試營運保護隱私觀測 RPC (Privacy-Preserving Pilot Operational Metrics)
--
-- 派生自最小試營運方案需求：
-- 1. 依校區、活動、時間區間聚合需求量、成團率與等待時長
-- 2. 嚴格出席界線：只有 arrived_at 或 ATTENDED 事件算作已驗證出席；
--    超時 fallback (A4) 自動結案且無到場者，標記為 UNKNOWN (unverified_completion_members)
-- 3. 計算不重複參與者與重複參與率（再次參與）
-- 4. 統計檢舉案件分類 (SPAM/HARASSMENT/OTHER) 與意見回饋
-- 5. 零 PII 洩漏：僅輸出數值與分類計數，絕不回傳個別使用者資訊
-- 6. 未知欄位忠實標記為 UNKNOWN
-- =============================================================================

create or replace function get_pilot_operational_metrics(
  p_school school default 'NYCU',
  p_campus text default '光復',
  p_since timestamptz default (now() - interval '7 days'),
  p_until timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_demand_total int := 0;
  v_demand_matched int := 0;
  v_demand_expired int := 0;
  v_demand_cancelled int := 0;
  v_avg_wait numeric := null;
  v_median_wait numeric := null;

  v_act_total int := 0;
  v_act_completed int := 0;
  v_act_cancelled int := 0;
  v_act_ongoing int := 0;

  v_verified_attended int := 0;
  v_unverified_completion int := 0;
  v_no_show int := 0;

  v_unique_users int := 0;
  v_repeat_users int := 0;
  v_repeat_rate numeric := 0;

  v_total_reports int := 0;
  v_pending_reports int := 0;
  v_spam_reports int := 0;
  v_harass_reports int := 0;
  v_other_reports int := 0;
  v_feedbacks int := 0;
begin
  -- 1. 需求量與等待時間 (Demand & Wait Times)
  select
    count(*),
    count(*) filter (where status = 'MATCHED'),
    count(*) filter (where status = 'EXPIRED'),
    count(*) filter (where status = 'CANCELLED')
  into
    v_demand_total,
    v_demand_matched,
    v_demand_expired,
    v_demand_cancelled
  from match_request
  where created_at >= p_since and created_at <= p_until
    and (p_school is null or school = p_school)
    and (p_campus is null or campus = p_campus);

  -- 成團等待時間（自建立至 Activity 成立的時間差，分鐘）
  with matched_waits as (
    select distinct r.id, extract(epoch from (a.created_at - r.created_at)) / 60.0 as wait_minutes
    from match_request r
    join activity_member am on am.source_request_id = r.id
    join activity a on a.id = am.activity_id
    where r.status = 'MATCHED'
      and r.created_at >= p_since and r.created_at <= p_until
      and (p_school is null or r.school = p_school)
      and (p_campus is null or r.campus = p_campus)
  )
  select
    round(avg(wait_minutes)::numeric, 1),
    round((percentile_cont(0.5) within group (order by wait_minutes))::numeric, 1)
  into
    v_avg_wait,
    v_median_wait
  from matched_waits;

  -- 2. 活動成團與出席 (Activities & Attendance)
  select
    count(*),
    count(*) filter (where status = 'COMPLETED'),
    count(*) filter (where status = 'CANCELLED'),
    count(*) filter (where status in ('MATCHED', 'ONGOING'))
  into
    v_act_total,
    v_act_completed,
    v_act_cancelled,
    v_act_ongoing
  from activity
  where created_at >= p_since and created_at <= p_until
    and (p_school is null or school = p_school)
    and (p_campus is null or campus = p_campus);

  -- 實際出席判定（不可將成團直接視為出席）
  with member_evidence as (
    select
      am.activity_id,
      am.user_id,
      a.status as activity_status,
      (am.arrived_at is not null or exists (
        select 1 from user_reliability_event ure
        where ure.activity_id = am.activity_id and ure.user_id = am.user_id and ure.event_type = 'ATTENDED'
      )) as is_verified_attended,
      exists (
        select 1 from user_reliability_event ure
        where ure.activity_id = am.activity_id and ure.user_id = am.user_id and ure.event_type = 'NO_SHOW'
      ) as is_no_show
    from activity_member am
    join activity a on a.id = am.activity_id
    where a.created_at >= p_since and a.created_at <= p_until
      and (p_school is null or a.school = p_school)
      and (p_campus is null or a.campus = p_campus)
      and am.status = 'JOINED'
  )
  select
    count(*) filter (where is_verified_attended),
    count(*) filter (where activity_status = 'COMPLETED' and not is_verified_attended and not is_no_show),
    count(*) filter (where is_no_show)
  into
    v_verified_attended,
    v_unverified_completion,
    v_no_show
  from member_evidence;

  -- 3. 再次參與與回訪率 (Retention & Repeat Participation)
  with period_users as (
    select distinct r.owner_id as user_id
    from match_request r
    where r.created_at >= p_since and r.created_at <= p_until
      and (p_school is null or r.school = p_school)
      and (p_campus is null or r.campus = p_campus)
  ),
  user_counts as (
    select
      pu.user_id,
      (
        select count(distinct mr.id)
        from match_request mr
        where mr.owner_id = pu.user_id
          and mr.created_at <= p_until
      ) as total_requests_count
    from period_users pu
  )
  select
    count(*)::int,
    count(*) filter (where total_requests_count >= 2)::int,
    case
      when count(*) > 0 then round((count(*) filter (where total_requests_count >= 2)::numeric / count(*)::numeric), 3)
      else 0.000
    end
  into
    v_unique_users,
    v_repeat_users,
    v_repeat_rate
  from user_counts;

  -- 4. 檢舉與需要人工處理之原因 (Issues, Reports & Workload)
  select
    count(*),
    count(*) filter (where status = 'PENDING'),
    count(*) filter (where category = 'SPAM'),
    count(*) filter (where category = 'HARASSMENT'),
    count(*) filter (where category = 'OTHER')
  into
    v_total_reports,
    v_pending_reports,
    v_spam_reports,
    v_harass_reports,
    v_other_reports
  from report
  where created_at >= p_since and created_at <= p_until;

  select count(*) into v_feedbacks
  from feedback
  where created_at >= p_since and created_at <= p_until;

  return jsonb_build_object(
    'scope', jsonb_build_object(
      'school', p_school,
      'campus', p_campus,
      'since', p_since,
      'until', p_until
    ),
    'demand', jsonb_build_object(
      'total_requests', v_demand_total,
      'matched_requests', v_demand_matched,
      'expired_requests', v_demand_expired,
      'cancelled_requests', v_demand_cancelled,
      'avg_wait_to_match_minutes', v_avg_wait,
      'median_wait_to_match_minutes', v_median_wait,
      'cancelled_wait_minutes', 'UNKNOWN',
      'cancelled_reasons', 'UNKNOWN'
    ),
    'attendance', jsonb_build_object(
      'total_activities', v_act_total,
      'completed_activities', v_act_completed,
      'cancelled_activities', v_act_cancelled,
      'ongoing_or_matched_activities', v_act_ongoing,
      'verified_attended_members', v_verified_attended,
      'unverified_completion_members', v_unverified_completion,
      'no_show_members', v_no_show,
      'unverified_note', 'A4 timeout completion without arrival check-in or settlement is marked as UNKNOWN'
    ),
    'retention', jsonb_build_object(
      'unique_participants', v_unique_users,
      'repeat_participants', v_repeat_users,
      'repeat_participation_rate', v_repeat_rate
    ),
    'issues_and_workload', jsonb_build_object(
      'total_reports', v_total_reports,
      'pending_reports', v_pending_reports,
      'reports_by_category', jsonb_build_object(
        'SPAM', v_spam_reports,
        'HARASSMENT', v_harass_reports,
        'OTHER', v_other_reports
      ),
      'feedbacks_count', v_feedbacks,
      'notification_delivery_failures', 'PARTIALLY_UNKNOWN (only invalid push subscriptions 404/410 tracked via cleanup)',
      'weekly_maintenance_hours', 'UNKNOWN (manual log required)'
    )
  );
end;
$$;

-- 權限控制：僅限後端 service_role，不對一般 authenticated 使用者開放（保護整體營運指標隱私）
revoke execute on function get_pilot_operational_metrics(school, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function get_pilot_operational_metrics(school, text, timestamptz, timestamptz) to service_role;
