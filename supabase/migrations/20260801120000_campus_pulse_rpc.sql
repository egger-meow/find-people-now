-- =============================================================================
-- Campus Activity Pulse — RPC (v1.26)
--
-- 首頁「🔥 光復校區 🏀 3 個籃球局配對中」這類即時氣氛指標。刻意不直接讓
-- client 查 `match_request`——那張表的 RLS（`my_requests_select`）只放行
-- owner/成員自己看得到，這是盲配設計的核心邊界（SPEC §11：配對成立前不能
-- 讓任何人看到候選對象的個人資料）。這支 RPC 只回傳「(school, campus,
-- activity_type) 底下有幾個 REQUESTING 中的 Request」這個聚合數字，不透露
-- 任何一筆 Request 的擁有者、時間窗或其他細節，跟盲配原則不衝突。
--
-- 只算 REQUESTING：DRAFT 還沒送出、PENDING_CONFIRMATION 已經在跟候選人
-- 互動、MATCHED/EXPIRED/CANCELLED 都不是「還在等人加入」的狀態，只有
-- REQUESTING 符合「現在加入這個活動類型，有機會湊到人」的語意。
-- =============================================================================

create or replace function get_campus_pulse(
  p_school school,
  p_campus text
)
returns table (
  activity_type_id   uuid,
  activity_type_name text,
  request_count      int
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  return query
    select mr.activity_type_id, at.name, count(*)::int
      from match_request mr
      join activity_type at on at.id = mr.activity_type_id
     where mr.status = 'REQUESTING'
       and mr.school = p_school
       and mr.campus = p_campus
     group by mr.activity_type_id, at.name
     order by count(*) desc;
end;
$$;
