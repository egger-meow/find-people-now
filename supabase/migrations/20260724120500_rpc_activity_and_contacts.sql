-- =============================================================================
-- Phase 6 RPCs — Activity Lifecycle & Dynamic Contact Export
-- 派生自 docs/SPEC.md §9、§11 及 docs/API.md §6
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc: get_activity_contacts
-- 動態倒數/雙向再約聯絡方式唯一出口 (不複製資料至 Activity)
-- -----------------------------------------------------------------------------

create or replace function get_activity_contacts(p_activity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_activity    activity;
  v_is_visible  boolean := false;
  v_members     jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_activity
    from activity
   where id = p_activity_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  -- 檢查呼叫者是否為該活動成員
  if not exists (
    select 1 from activity_member
     where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
  ) then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  -- 判斷基礎時效：now() < contact_visible_until (+24h)
  v_is_visible := (now() < v_activity.contact_visible_until);

  -- 動態組裝成員清單與聯絡方式（聯絡資訊純留在 app_user，動態導出）
  select jsonb_agg(
    jsonb_build_object(
      'user_id', u.id,
      'display_name', u.display_name,
      'avatar_url', u.avatar_url,
      'role', am.status,
      -- 若 24h 未過期，或與對方有雙向 rematch_vote，才顯示聯絡方式 (SPEC §11)
      'contacts', case
        when v_is_visible or exists (
          select 1 from rematch_vote rv1
           join rematch_vote rv2 on rv1.activity_id = rv2.activity_id
          where rv1.activity_id = p_activity_id
            and rv1.from_user_id = v_user_id and rv1.to_user_id = u.id
            and rv2.from_user_id = u.id and rv2.to_user_id = v_user_id
        ) then jsonb_build_object(
          'contact_ig', u.contact_ig,
          'contact_line', u.contact_line,
          'contact_discord', u.contact_discord
        )
        else null
      end
    )
  ) into v_members
  from activity_member am
  join app_user u on u.id = am.user_id
 where am.activity_id = p_activity_id;

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'contact_visible_until', v_activity.contact_visible_until,
    'members', coalesce(v_members, '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. rpc: cancel_activity_participation
-- 個別成員取消活動 (A5/A6)
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

  -- 依時間點判定懲罰分級 (SPEC §10)：開始前 >= 1h 為 EARLY_CANCEL，否則為 LATE_CANCEL
  if now() < v_activity.start_time - interval '1 hour' then
    v_event_type := 'EARLY_CANCEL';
  else
    v_event_type := 'LATE_CANCEL';
  end if;

  -- 寫入 Reliability 事件
  insert into user_reliability_event (user_id, activity_id, event_type)
  values (v_user_id, p_activity_id, v_event_type);

  -- LATE_CANCEL 觸發 30 分鐘冷卻 (v1.7，SPEC §6.3)；EARLY_CANCEL 屬正常改行程，不觸發
  if v_event_type = 'LATE_CANCEL' then
    update app_user set next_request_allowed_at = now() + interval '30 minutes' where id = v_user_id;
  end if;

  -- 更新成員狀態
  update activity_member
     set status = 'CANCELLED'
   where activity_id = p_activity_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'event_type', v_event_type);
end;
$$;
