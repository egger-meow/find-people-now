-- =============================================================================
-- 啟用 pg_cron，正式排程所有背景任務（v1.22）
--
-- 根因：全 repo 搜尋不到任何 cron.schedule(...) 呼叫。20260724121500_
-- campus_scope_rpc.sql、20260724122200_background_jobs_rpc.sql 等檔案的檔頭
-- 註解都明確寫「這輪只做成 callable function，不掛 pg_cron.schedule」——這是
-- 過去每一輪刻意擱置的既有決定，不是意外遺漏，但代表系統目前完全不會自動
-- 觸發配對/過期/提醒——這些函式都存在、都測試過，只是從來沒有東西真的呼叫它們。
-- 也確認過 .github/workflows/supabase-db-tests.yml 只在 push/PR 時跑 pgTAP，
-- 沒有 schedule 觸發；supabase/functions/ 底下只有 delete-auth-user 一個
-- Edge Function（帳號刪除用，非排程）；repo 內沒有任何其他 CI/CD 或外部排程
-- 設定檔案會呼叫這些函式。
--
-- 這裡補上 pg_cron 排程，涵蓋 API.md §9 列出的全部背景任務，外加
-- fn_remind_upcoming_activities()（v1.21 新增，該輪文件沒被列進「尚待排程」
-- 清單，但性質同一類，這裡一併補上，不留缺口）。
--
-- 頻率分兩級，依各函式的時間敏感度決定，不是統一頻率：
--
--   30 秒 — fn_run_matching_engine()：撮合本身是核心體驗，REQUESTING 的使用者
--   在等待室即時等結果（見 app/lib/match/waiting_room_screen.dart 的 Realtime
--   訂閱），30 秒是「夠即時」與「不過度打資料庫」的折衷；已在
--   20260724125400_matching_engine_advisory_lock.sql 加上 advisory lock，
--   避免執行時間萬一超過 30 秒時跟下一輪重疊。
--
--   1 分鐘 — fn_start_activities()：MATCHED → ONGOING 的轉移點，同時鎖定
--   Activity Location（20260724121500_campus_scope_rpc.sql）。使用者會在
--   start_time 當下期待活動狀態更新，這裡給比過期/提醒類更高的頻率。
--
--   2 分鐘 — fn_cleanup_pending_confirmations() / fn_expire_downgrades()：
--   兩者都在收斂一個 10 分鐘的 CONSENT_WINDOW（respond_pending_confirmation /
--   respond_downgrade，見 20260724122200_background_jobs_rpc.sql:223）。
--   2 分鐘輪詢讓「已超時但還沒被清理」的視窗，相對 10 分鐘總窗保持在合理比例
--   內，不會讓使用者等太久才看到「配對未成立」通知或 Request 被放回 Queue。
--
--   5 分鐘 — fn_expire_requests()（R4，24 小時邊界）、
--   fn_remind_missing_location_candidates()（提醒 lead time 是設定值，見
--   app_config `location_reminder_lead_minutes`，通常是幾十分鐘量級）、
--   fn_remind_completions()（activity.estimated_end_time 一過就該提醒）：
--   都是「幾分鐘誤差不影響體驗」的類型，5 分鐘是使用者體驗跟資料庫負載的折衷。
--
--   15 分鐘 — fn_complete_activities()（A4，24 小時 + 已經過 estimated_end_time
--   的 fallback 強制結案，本來就不期待準時）、fn_remind_upcoming_activities()
--   （提前提醒，lead time 同樣是設定值的小時量級）：這兩個函式的判準都是
--   「已經晚了才補救」或「還很早的提前提醒」，誤差幾分鐘完全不影響。
--
-- 依 pg_cron 官方文件，同時排程的 job 數上限是 32、且建議錯開執行時間避免
-- connection 尖峰——這裡總共 9 個 job，錯開秒數／分鐘數起點，不會撞在同一刻。
-- =============================================================================

create extension if not exists pg_cron;

-- 30 秒
select cron.schedule('run-matching-engine', '30 seconds', $$select fn_run_matching_engine();$$);

-- 1 分鐘
select cron.schedule('start-activities', '* * * * *', $$select fn_start_activities();$$);

-- 2 分鐘（10 分鐘 CONSENT_WINDOW 收斂類，起點錯開 0/1 分鐘避免同時搶連線）
select cron.schedule('cleanup-pending-confirmations', '*/2 * * * *', $$select fn_cleanup_pending_confirmations();$$);
select cron.schedule('expire-downgrades', '1-59/2 * * * *', $$select fn_expire_downgrades();$$);

-- 5 分鐘（提醒/過期類，起點錯開 0/2/4 分鐘）
select cron.schedule('expire-requests', '*/5 * * * *', $$select fn_expire_requests();$$);
select cron.schedule('remind-missing-location-candidates', '2-59/5 * * * *', $$select fn_remind_missing_location_candidates();$$);
select cron.schedule('remind-completions', '4-59/5 * * * *', $$select fn_remind_completions();$$);

-- 15 分鐘（fallback/提前提醒類，起點錯開 0/7 分鐘）
select cron.schedule('complete-activities', '*/15 * * * *', $$select fn_complete_activities();$$);
select cron.schedule('remind-upcoming-activities', '7-59/15 * * * *', $$select fn_remind_upcoming_activities();$$);
