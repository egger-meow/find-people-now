-- =============================================================================
-- 修正 get_campus_pulse：改算人頭，不算 Request 筆數（v1.39）
--
-- 原本 `count(*)` 算的是 REQUESTING 中的 match_request 列數——但一個 Request
-- 可能已經透過邀請連結帶了不只一位成員（request_member，見 v1.1 設計備註
-- 「取代 member_ids[]」），列數 ≠ 目前實際在等的人數。使用者實測發現：兩個
-- 各自獨立、都還缺 2 人的健身局，被算成「2 組配對中」，但「組」這個字眼讓
-- 使用者誤以為快湊滿了，跟「其實各自都還孤身一人在等」的真實情況不符——
-- 首頁氣氛指標的目的是讓使用者對「現在有多少人氣」有正確直覺，用 Request
-- 筆數而非人頭數，在有邀請連結預先湊到多人的情況下會低估實際人數，語意上
-- 也容易被誤讀成「已成局的組數」。
--
-- 改為 join request_member（status = 'JOINED'）算實際人頭，並把回傳欄位從
-- `request_count` 更名為 `person_count`，避免欄位名稱本身繼續帶著「算 Request
-- 不是算人」的錯誤暗示（沿用 v1.14 修 errcode 誤用時的態度：光改邏輯不改
-- 容易誤導的命名，下次還是會有人看名字猜錯語意）。
-- =============================================================================

-- `create or replace function` 不能改 OUT 參數（回傳欄位）的形狀/名稱，
-- 必須先 drop 再重建。
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
       and mr.school = p_school
       and mr.campus = p_campus
     group by mr.activity_type_id, at.name
     order by count(rm.*) desc;
end;
$$;
