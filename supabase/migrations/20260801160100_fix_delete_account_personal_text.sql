-- =============================================================================
-- 修正 delete_account：補清 activity_member 上的個人化自由文字欄位
--
-- 根因：delete_account()（v1.14）逐表去識別化清單裡從未涵蓋
-- activity_member.meeting_hint（v1.11.1，比 delete_account 還早存在）跟
-- .vibe_tags（v1.28，這輪新增）——這兩欄都是使用者自己打的自由文字，
-- 對其他活動成員可見（my_activity_members_select policy 是整列可見，不分欄），
-- 且沒有時效性：即使活動早已 COMPLETED，這兩欄的值依然留在資料庫裡，
-- 其他曾經同組的成員隨時查得到那個活動的 activity_member 列時都看得到。
--
-- 這不是「比照 meeting_hint 當初的處理方式」——meeting_hint 從來沒被
-- delete_account 處理過，這是既有的遺漏，vibe_tags 只是重複踩了同一個坑。
-- 兩者都可能包含使用者自己打進去的姓名/聯絡方式等識別資訊（例如「找王小明」
-- 「call我0912...」），去識別化 app_user 本體卻放著這種自由文字不管，
-- 沒有真正達成「移除可識別資訊」的目的。
--
-- 修法：新增一段 UPDATE，清空該使用者名下*所有*（不限目前 status、不限
-- activity 是否仍在進行中）activity_member 列的 meeting_hint/vibe_tags——
-- 覆寫成 null，不像 app_user 那樣需要固定佔位字串（兩欄本來就是 nullable，
-- 語意上「沒填」就是 null，不需要偽造內容）。arrived_at 不動：那只是一個
-- 時間戳事實，不含自由輸入內容，不具識別力，跟 user_reliability_event
-- 保留不動的理由相同。
-- =============================================================================

create or replace function delete_account()
returns jsonb
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
    return jsonb_build_object('success', true, 'already_deleted', true);
  end if;

  if not exists (select 1 from app_user where id = v_user_id) then
    return jsonb_build_object('success', true, 'had_profile', false);
  end if;

  update match_request
     set status = 'CANCELLED'
   where owner_id = v_user_id
     and status in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION');

  update request_member rm
     set status = 'LEFT'
   where rm.user_id = v_user_id
     and rm.status = 'JOINED'
     and exists (
       select 1 from match_request mr
        where mr.id = rm.request_id
          and mr.owner_id <> v_user_id
          and mr.status in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION')
     );

  update activity_member
     set status = 'CANCELLED'
   where user_id = v_user_id
     and status = 'JOINED'
     and activity_id in (select id from activity where status in ('MATCHED', 'ONGOING'));

  -- 新增：清空這個使用者名下所有 activity_member 列的個人化自由文字欄位，
  -- 不限目前 status、不限所屬 activity 是否仍在進行中——已結束活動的舊列
  -- 也要清，因為那些自由文字仍然對當年的同組成員永久可見。
  update activity_member
     set meeting_hint = null,
         vibe_tags    = null
   where user_id = v_user_id
     and (meeting_hint is not null or vibe_tags is not null);

  delete from notification where user_id = v_user_id;

  delete from match_history_avoidance where user_a_id = v_user_id or user_b_id = v_user_id;

  update app_user
     set email                    = 'deleted+' || v_user_id::text,
         display_name             = '已刪除的使用者',
         avatar_url                = '',
         gender                    = null,
         bio                       = null,
         department                = null,
         contact_ig                = null,
         contact_line              = '[已刪除帳號]',
         contact_discord           = null,
         suspended_until           = null,
         next_request_allowed_at   = null,
         deleted_at                = now()
   where id = v_user_id;

  return jsonb_build_object('success', true, 'had_profile', true);
end;
$$;
