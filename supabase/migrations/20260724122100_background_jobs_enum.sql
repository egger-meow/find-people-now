-- =============================================================================
-- 背景任務補齊（一）：新增 notification_event_type 值 MATCH_NOT_FORMED
-- 對應 API.md §9「PENDING_CONFIRMATION 超時與拒絕清理」原本就寫明要發的
-- 「配對未成立」無差別通知（不歸因原則同 ERD 備註 16），但 fn_cleanup_pending_confirmations
-- 從未真的發過。ALTER TYPE ... ADD VALUE 必須在自己的 transaction/migration 內先落地
-- 才能在同一批次的下一個 migration 使用，比照 20260724121400/20260724121700 的既有慣例。
-- =============================================================================

alter type notification_event_type add value if not exists 'MATCH_NOT_FORMED';

-- 順手修正一處過期文件說明：downgrade_consent_window_minutes 建立時的註解寫著
-- 「目前尚無 RPC 建立 downgrade_request，此值供未來實作使用」——本輪
-- fn_expire_requests() 是第一個真正建立 downgrade_request 的呼叫點，補正描述。
update app_config
   set description = 'Downgrade 同意窗口時長（SPEC §8）；fn_expire_requests() 建立 downgrade_request 時使用'
 where key = 'downgrade_consent_window_minutes';
