-- =============================================================================
-- rpc: respond_downgrade — docs/API.md §5.1
-- 派生自 STATE_MACHINE.md「Downgrade 子流程（掛在 REQUESTING 內部）」與 ERD.md
-- 設計備註 21。之前完全沒有實作：downgrade_request/downgrade_consent 兩張表與
-- RLS policy 從 init migration 就存在，但沒有任何 RPC 讓使用者回應，這個功能
-- 對使用者來說形同不存在。
--
-- 範圍：只補「使用者回應」這個 endpoint。downgrade_request 的建立（STATE_MACHINE
-- 表列「到 latest_start 前仍未達 min_participants 且 allow_downgrade=true 且剩餘
-- 時間 >= 10 分鐘」）是背景任務（docs/API.md §9「Request 過期」排程）的職責，不是
-- client 可呼叫的 RPC（API.md §5.1 原文：「發起端是系統（Matching Engine）,沒有
-- 使用者發起的 endpoint」）——那個排程本身尚未實作，超出本次任務範圍，不在此補。
-- =============================================================================

create or replace function respond_downgrade(
  p_downgrade_request_id uuid,
  p_agree                 boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_dg         downgrade_request;
  v_consent    downgrade_consent;
  v_min        int;
  v_new_resp   downgrade_response;
  v_total      int;
  v_agreed     int;
begin
  if v_user_id is null then
    raise exception using message = 'UNAUTHORIZED';
  end if;

  select * into v_dg from downgrade_request where id = p_downgrade_request_id for update;

  if not found then
    raise exception using message = 'NOT_FOUND', detail = 'DOWNGRADE_REQUEST_NOT_FOUND';
  end if;

  -- 呼叫者必須是被詢問名單之一（downgrade_consent 的名單來源 = 建立時展開的
  -- request_member，見 init migration 的表註解）
  select * into v_consent
    from downgrade_consent
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id
     for update;

  if not found then
    raise exception using message = 'FORBIDDEN', detail = 'NOT_PARTY_TO_DOWNGRADE';
  end if;

  -- ERD 設計備註 21：target_size 必須低於原 min_participants，回應 RPC 也要應用層比對
  -- （不只建立時檢查一次），防止資料被非預期方式寫壞後還被回應 RPC 當合法狀態處理
  select min_participants into v_min from match_request where id = v_dg.request_id;
  if v_min is null or v_dg.target_size >= v_min then
    raise exception using message = 'INVALID_INPUT', detail = 'DOWNGRADE_TARGET_SIZE_NOT_BELOW_MIN_PARTICIPANTS';
  end if;

  -- 10 分鐘 CONSENT_WINDOW；超時 = 拒絕，Request 以原門檻回池（SPEC §8）——這裡只
  -- 擋「已經過期還想回應」，實際把 Request 留在原門檻是背景清理任務的職責（同
  -- fn_cleanup_pending_confirmations 的分工模式），不在本 RPC 內處理
  if v_dg.status <> 'PENDING' or v_dg.expire_at < now() then
    raise exception using message = 'CONSENT_WINDOW_CLOSED';
  end if;

  if v_consent.response <> 'NO_RESPONSE' then
    raise exception using message = 'ALREADY_RESPONDED';
  end if;

  v_new_resp := case when p_agree then 'AGREE'::downgrade_response else 'DISAGREE'::downgrade_response end;

  update downgrade_consent
     set response = v_new_resp, responded_at = now()
   where downgrade_request_id = p_downgrade_request_id and user_id = v_user_id;

  if p_agree = false then
    -- 任一人 DISAGREE → 立即 REJECTED（STATE_MACHINE：「任一人 DISAGREE →
    -- downgrade_request → REJECTED，Request 以原 min/max_participants 留在池中」）
    update downgrade_request set status = 'REJECTED' where id = p_downgrade_request_id;
  else
    -- 全員 AGREE 才 APPROVED；重新以 target_size 撮合是 Matching Engine（§9）的
    -- 職責，本 RPC 只負責原子性的狀態轉移
    select count(*), count(*) filter (where response = 'AGREE')
      into v_total, v_agreed
      from downgrade_consent
     where downgrade_request_id = p_downgrade_request_id;

    if v_agreed = v_total then
      update downgrade_request set status = 'APPROVED' where id = p_downgrade_request_id;
    end if;
  end if;

  return jsonb_build_object('success', true);
end;
$$;
