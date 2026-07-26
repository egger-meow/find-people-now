-- =============================================================================
-- Meeting Point / Meeting Hint — RPC (v1.11.1)
--
-- 兩者皆獨立於 activity_location_id 是否鎖定／投票結果 —— 只要 activity 存在
-- 就可以用（不要求 status = MATCHED），這樣「正式候選地點沒投出結果」不等於
-- 「系統內沒有任何協調工具可用」（SPEC v1.11 §9.1 的既有原則，這裡才是實作）。
--
-- 邊界判斷（COMPLETED/CANCELLED 之後要不要還能修改，SPEC 原文交待由這輪自行評估）：
-- 兩支 RPC 都限制 activity.status in ('MATCHED', 'ONGOING')。理由：Meeting
-- Point/Hint 存在的目的是幫參與者「在活動結束前」對齊集合資訊；活動一旦
-- COMPLETED 或 CANCELLED，協調動作已經沒有實質對象（COMPLETED 沒有人還要去
-- 集合；CANCELLED 活動根本不會發生），繼續允許修改只會產生沒有意義的通知，
-- 也會讓「活動記錄」在事後被繼續竄改。跟 propose_activity_location/
-- vote_activity_location 限制在 MATCHED 的邏輯相同精神，但這裡刻意放寬到
-- ONGOING（規格原文明確説「不用限定在 MATCHED」——活動當天仍可能需要修正
-- 集合點）。
-- =============================================================================

create or replace function update_meeting_point(
  p_activity_id uuid,
  p_description text
)
returns activity_meeting_point_update
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_desc     text := trim(p_description);
  v_result   activity_meeting_point_update;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if v_desc is null or v_desc = '' then
    raise exception using message = 'INVALID_INPUT', detail = 'DESCRIPTION_REQUIRED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if not exists (
    select 1 from activity_member am
     where am.activity_id = p_activity_id and am.user_id = v_user_id and am.status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  -- 2 分鐘冷卻：直接查「該使用者對該活動最近一次更新是否在冷卻窗口內」，
  -- 不另開欄位存狀態（跟 known_member_count 同一個精神）。
  if exists (
    select 1 from activity_meeting_point_update
     where activity_id = p_activity_id
       and updated_by = v_user_id
       and created_at > now() - fn_get_config_interval('meeting_point_update_cooldown_minutes')
  ) then
    raise exception using message = 'MEETING_POINT_UPDATE_COOLDOWN';
  end if;

  insert into activity_meeting_point_update (activity_id, updated_by, description)
  values (p_activity_id, v_user_id, v_desc)
  returning * into v_result;

  insert into notification (user_id, event_type, payload)
  select am.user_id, 'MEETING_POINT_UPDATED',
         jsonb_build_object('activity_id', p_activity_id, 'description', v_desc, 'updated_by', v_user_id)
    from activity_member am
   where am.activity_id = p_activity_id and am.status = 'JOINED';

  return v_result;
end;
$$;

create or replace function update_meeting_hint(
  p_activity_id uuid,
  p_hint text
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_hint     text := nullif(trim(p_hint), '');
  v_result   activity_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if v_hint is not null and char_length(v_hint) > 30 then
    raise exception using message = 'INVALID_INPUT', detail = 'HINT_TOO_LONG';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  update activity_member
     set meeting_hint = v_hint
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  returning * into v_result;

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  return v_result;
end;
$$;
