-- =============================================================================
-- 修正 mark_arrived 的並發競態 + 補上 ACCOUNT_DELETED 檢查
--
-- 根因：原版（20260801100100_arrival_check_rpc.sql）的冪等判斷是「先 SELECT
-- arrived_at is not null，再視情況 UPDATE」兩個步驟分開執行，不是原子操作。
-- 兩個並發呼叫可以都通過「還沒抵達」的檢查（此時都還沒有任何一方寫入），
-- 各自繼續往下執行 UPDATE 並各自送出一次 MEMBER_ARRIVED 通知給其他成員——
-- arrived_at 最終值不會錯（兩次 UPDATE 都寫自己的 now()，值很接近但無傷大雅），
-- 但通知會被送兩次，洗版其他成員的通知匣。這正是 CLAUDE.md 記錄過的既有教訓
-- 的同一類問題（PC1 死迴圈／matching engine cursor snapshot），只是這次發生在
-- 一支更新的 RPC 上。
--
-- 修法：改成 `UPDATE ... WHERE arrived_at IS NULL RETURNING`。UPDATE 陳述式
-- 本身在單一陳述式內完成「條件檢查 + 取得列鎖 + 寫入」，是原子的——並發呼叫
-- 中只有一個會真正把 NULL 改成非 NULL 並 FOUND，另一個會落空，用一次額外
-- SELECT 分辨「已經抵達過」（冪等，回傳現有 row）跟「本來就不是成員」
-- （NOT_ACTIVITY_MEMBER）。
--
-- 順便補上 ACCOUNT_DELETED 檢查：v1.14 起「所有 auth.uid()-driven RPC 都要檢查」
-- 是持續在維護的既有慣例（v1.18 submit_report 仍照做），這支函式當初漏掉了。
-- =============================================================================

create or replace function mark_arrived(
  p_activity_id uuid
)
returns activity_member
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_activity activity;
  v_result   activity_member;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_activity from activity where id = p_activity_id;
  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.status not in ('MATCHED', 'ONGOING') then
    raise exception using message = 'ACTIVITY_NOT_ACTIVE';
  end if;

  update activity_member
     set arrived_at = now()
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED'
     and arrived_at is null
  returning * into v_result;

  if found then
    insert into notification (user_id, event_type, payload)
    select am.user_id, 'MEMBER_ARRIVED',
           jsonb_build_object(
             'activity_id', p_activity_id,
             'arrived_user_id', v_user_id,
             'display_name', (select display_name from app_user where id = v_user_id)
           )
      from activity_member am
     where am.activity_id = p_activity_id and am.status = 'JOINED' and am.user_id != v_user_id;

    return v_result;
  end if;

  -- UPDATE 落空有兩種可能：本來就不是這個活動的 JOINED 成員，或已經抵達過
  -- （冪等重複呼叫）——用一次額外的 SELECT 分辨兩者，回傳現有 row 或拋錯。
  select * into v_result from activity_member
   where activity_id = p_activity_id and user_id = v_user_id and status = 'JOINED';

  if not found then
    raise exception using message = 'NOT_ACTIVITY_MEMBER';
  end if;

  return v_result;
end;
$$;
