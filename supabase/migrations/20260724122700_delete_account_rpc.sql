-- =============================================================================
-- 帳號刪除（三）：delete_account() RPC（v1.14）— 業務資料清理 + 去識別化
--
-- 這支 RPC 只負責 public schema 的業務資料；auth.users 那一段（GoTrue soft
-- delete）由 Flutter 端在這支成功之後另外呼叫 Edge Function `delete-auth-user`
-- 完成（見對話中第 0 點的架構結論：service_role key 不能進 Flutter client，
-- 只有 Admin API 能正確清 GoTrue 內部的 sessions/refresh_tokens/identities）。
--
-- 不檢查 suspended_until：停權是懲罰性狀態，帳號刪除權不該被拿來當懲罰籌碼。
--
-- 逐表處理原則（對話中已逐一判斷，這裡不重複列出理由）：
--   - app_user row 保留、去識別化，id 不變 → 13 張子表全部不需要動 FK
--   - 仍在進行中的 match_request/request_member/activity_member 需要主動
--     轉終態，避免其他成員卡死等一個已經刪除的人
--   - notification（純自己的收件匣）與 match_history_avoidance（對方永遠不會
--     再進配對池，純死重量）直接硬刪除
--   - 其餘 9 張子表（activity_type/location.created_by、
--     activity_location_option/vote、activity_meeting_point_update、
--     downgrade_consent、completion_report、user_reliability_event、
--     rematch_vote）維持原樣不動：全都是其他成員仍在依賴的共用資料
--     （得票數/集合點/同意計票/結算稽核/可信度都是即時查詢，不會因為
--     app_user 的識別欄位被清空而變化），或純粹是無 PII 的歸屬 FK
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

  -- 冪等：已經刪除過，直接視為成功（比照 GoTrue admin.deleteUser 對已
  -- soft-delete 帳號重複呼叫的 no-op 行為，見對話中查證的 Go 原始碼：
  -- if user.DeletedAt != nil { return nil }）
  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    return jsonb_build_object('success', true, 'already_deleted', true);
  end if;

  -- 從未完成 onboarding（沒有 app_user row）就直接刪帳號：沒有業務資料可清，
  -- 直接放行讓 Flutter 端接著呼叫 Edge Function 清 auth.users
  if not exists (select 1 from app_user where id = v_user_id) then
    return jsonb_build_object('success', true, 'had_profile', false);
  end if;

  -- 1. 仍在進行中的 Request：自己是 owner → 直接 CANCELLED，避免其他已加入的
  --    成員卡死等一個永遠不會再回應的 owner
  update match_request
     set status = 'CANCELLED'
   where owner_id = v_user_id
     and status in ('DRAFT', 'REQUESTING', 'PENDING_CONFIRMATION');

  -- 2. 仍在進行中的 Request：自己是非 owner 成員 → 退出 (LEFT)，比照
  --    leave_request 的效果，不影響其他成員湊團
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

  -- 3. 仍在進行中的 Activity：自己是成員 → CANCELLED。刻意不比照
  --    cancel_activity_participation 寫 Reliability 事件、不觸發冷卻——這是
  --    「離開平台」，不是失信行為，沒有未來要懲罰的對象
  update activity_member
     set status = 'CANCELLED'
   where user_id = v_user_id
     and status = 'JOINED'
     and activity_id in (select id from activity where status in ('MATCHED', 'ONGOING'));

  -- 4. 純屬自己的收件匣，沒有其他人依賴，直接清空
  delete from notification where user_id = v_user_id;

  -- 5. 配對避雷紀錄：自己永遠不會再進配對池，殘留的 pair 對任何一方都沒有
  --    產品意義，直接清掉
  delete from match_history_avoidance where user_a_id = v_user_id or user_b_id = v_user_id;

  -- 6. app_user 去識別化：row 保留、id 不變。email 用 id 組出保證唯一的佔位
  --    值（不再偽造符合雙校網域格式的假信箱）；display_name/avatar_url 有
  --    NOT NULL 門檻，用固定佔位字串/空字串；contact_* 的
  --    at_least_one_contact CHECK 要求至少一項非空，留 contact_line 一項
  --    佔位、其餘清空；degree_level/school 刻意保留不清（粗粒度分類，去掉
  --    姓名/照片/聯絡方式後不具單獨識別力，且 school 被 school_matches_email
  --    綁死要跟新 email 一致）
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
