-- =============================================================================
-- 補上 SPEC.md §12.1.3「安全資訊卡」從未有對應 RPC 的落差（v1.22）
-- =============================================================================
-- 發現經過：「我的活動」前端 round 1 盤點 PENDING_CONFIRMATION 卡片需要的資料
-- 時，對照 SPEC.md §12.1.3 才發現——安全資訊卡明確要求展示對方的頭像、姓名、
-- school、department、degree_level、Reliability 等級、已完成活動次數，但
-- get_pending_confirmation_status（4.1）只回傳 pending_confirmation 本身的
-- status/倒數，`pending_confirmation` 表 RLS 又刻意不開 SELECT policy（ERD
-- 設計備註 16），前端完全沒有路徑能拿到這份資料。這不是「有實作但沒測過」的
-- pgcrypto/search_path 那種 bug，是文件定案後從未真正補上資料源的既有缺口。
--
-- 權限判準沿用 respond_pending_confirmation（4.2）已驗證過的模式：呼叫者須為
-- request_a/request_b 其中一方的 owner，否則 FORBIDDEN detail
-- NOT_PARTY_TO_CONFIRMATION；找不到 pending_confirmation_id 則 NOT_FOUND
-- detail PENDING_CONFIRMATION_NOT_FOUND——跟 4.1/4.2 用同一組錯誤碼。
--
-- 刻意不查詢、不回傳 user_a_response/user_b_response：這支 RPC 只補安全資訊
-- 卡需要的個人資料欄位，第 12.1.2 節的對稱不歸因原則不受影響。
-- =============================================================================

create or replace function get_pending_confirmation_candidate_info(p_pending_confirmation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_pc           pending_confirmation;
  v_other_owner  uuid;
  v_other        app_user;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  if exists (select 1 from app_user where id = v_user_id and deleted_at is not null) then
    raise exception using message = 'ACCOUNT_DELETED';
  end if;

  select * into v_pc
    from pending_confirmation
   where id = p_pending_confirmation_id;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'PENDING_CONFIRMATION_NOT_FOUND';
  end if;

  if exists (select 1 from match_request where id = v_pc.request_a_id and owner_id = v_user_id) then
    select owner_id into v_other_owner from match_request where id = v_pc.request_b_id;
  elsif exists (select 1 from match_request where id = v_pc.request_b_id and owner_id = v_user_id) then
    select owner_id into v_other_owner from match_request where id = v_pc.request_a_id;
  else
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_CONFIRMATION';
  end if;

  select * into v_other from app_user where id = v_other_owner;

  return jsonb_build_object(
    'display_name', v_other.display_name,
    'avatar_url', v_other.avatar_url,
    'school', v_other.school,
    'department', v_other.department,
    'degree_level', v_other.degree_level,
    'reliability_tier', fn_reliability_tier(v_other_owner),
    'completed_activity_count', (
      select count(*) from user_reliability_event
       where user_id = v_other_owner and event_type = 'ATTENDED'
    )
  );
end;
$$;

-- 不需要額外 grant execute：Postgres 對函式的 EXECUTE 預設就是 GRANT 給 PUBLIC
-- （見 20260724120800_grants.sql 的說明），跟其他 SECURITY DEFINER RPC 一致。
