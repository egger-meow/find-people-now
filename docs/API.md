# API Endpoint Spec — 校園活動配對 App（派生自 SPEC v1.21）

> 本文件由 [SPEC.md](SPEC.md) 推導，建立在 [ERD.md](ERD.md) v1.21 與 [STATE_MACHINE.md](STATE_MACHINE.md) v1.14 定案之上。若與 SPEC 衝突，先改 SPEC。

## 0. 總約定

- **後端形態**：Supabase。純讀取走 PostgREST（RLS 已在 migration 定義）；**所有狀態轉移一律走 RPC**（`security definer` Postgres function，經 `supabase.rpc()` 呼叫），client 不直接 update 狀態欄位。轉移的合法性以 [STATE_MACHINE.md](STATE_MACHINE.md) 為準（編號 R1–R5、PC1–PC2、A1–A6）。
- **RLS 專用受控存取**：`pending_confirmation` 與 `match_history_avoidance` 兩張表在 DB 層故意「啟用 RLS 但不安裝 SELECT Policy」，防止使用者直接讀取敏感資料。前端查詢候選配對狀態必須透過特定的 `SECURITY DEFINER` RPC（如 4.1 `get_pending_confirmation_status`），僅透露整體 `status`，嚴格隔離個案回應明細（落實 ERD 設計備註 16）。
- **驗證**：所有呼叫需 Supabase Auth JWT（信箱 OTP 登入）。`auth.uid()` 即操作者，request body 不帶 `user_id`。
- **錯誤格式（v1.7 修正）**：RPC 以 `raise exception using message = '<CODE>'`（需要更細節的子原因時另加 `detail = '<detail>'`）回傳；下表的「錯誤碼」即為 `message` 的值，PostgREST 會將其映射到回應 JSON 的 `message` 欄位，client 應以此欄位比對錯誤碼。🔴 **不使用 `errcode = '<CODE>'`**：PL/pgSQL 的 `errcode` 只接受標準 5 碼 SQLSTATE 或內建的 condition name，塞入任意自訂字串（如 `'UNAUTHORIZED'`）會在 `raise` 當下直接拋出 `unrecognized exception condition`，蓋掉原本要回傳的錯誤，導致這裡列出的所有錯誤碼實際上從未真正生效過；v1.7 已修正全部 6 個 RPC migration 檔案的 65 處呼叫。
- **停權檢查**：`suspended_until > now()` 的使用者呼叫任何寫入類 RPC 一律回 `USER_SUSPENDED`。
- **已刪除帳號檢查（v1.14）**：`app_user.deleted_at is not null` 的呼叫者，呼叫任一身分驗證類（`auth.uid()`-driven）RPC 一律回 `ACCOUNT_DELETED`，唯一例外是 1.5 `delete_account()` 本身（冪等，重複呼叫回傳 `already_deleted: true` 而不是報錯）。完整受檢 RPC 清單見 SPEC.md v1.14 變更紀錄第 5 點，不在此重複列出。
- **唯一偏離「純 RPC」慣例之處（v1.14）**：`auth.users` 的刪除（1.5 `delete_account()` 之後接續的一步）改走 Edge Function `supabase/functions/delete-auth-user/`，因為官方 Admin API `auth.admin.deleteUser()` 強制要求 `service_role` JWT，不能讓 Flutter client 持有這把 key；除此之外全部功能維持 SQL RPC，不新增第二支 Edge Function。

---

## 1. Auth / Profile

| # | Endpoint | 說明 |
|---|---|---|
| 1.1 | `auth.signInWithOtp({ email })` | Supabase 內建。前端先擋非 `@nycu.edu.tw` / `@nthu.edu.tw`；DB 端 `app_user.email` CHECK 為最終防線（SPEC §2：完整雙校網域比對，非 `.edu.tw` 後綴）。 |
| 1.2 | `rpc: complete_profile(display_name, avatar_url, degree_level, department?, gender?, bio?, contact_ig?, contact_line?, contact_discord?)` | 註冊硬性門檻（SPEC §2, v1.4）：`avatar_url` 必填 + `degree_level` (enum `UNDERGRAD\|MASTER\|PHD`) 必選 + 三項聯絡方式至少一項。`bio` 與 `department` 選填、不卡門檻。未完成必填項前所有 Request 類 RPC 回 `PROFILE_INCOMPLETE`。**`school` 不是參數**——由 email 網域 mapping（`nycu.edu.tw → NYCU`、`nthu.edu.tw → NTHU`）在 server 端寫入，DB CHECK 保證與網域一致（SPEC §2：不讓使用者自選）。 |
| 1.3 | `PATCH app_user`（PostgREST，RLS：own row） | 更新個人資料（含 `bio`, `department`）；DB CHECK 保證改完仍滿足硬性門檻與必填約束。也用於寫入 `onboarding_seen_at`（v1.20，新手上手引導卡片已讀時間戳，見 `docs/UI_PLAN.md` §11.1），不另開 RPC。 |
| 1.4 | `rpc: get_my_reliability()` | 回 `{ tier: TRUSTED\|NORMAL\|NEW, is_new_user: bool }`，即時由 `fn_reliability_tier` / `fn_is_new_user` 計算（SPEC §12：不存分數欄位）。 |
| 1.5 | `rpc: delete_account()` **接著** Edge Function `delete-auth-user`（v1.14） | **App 內建帳號刪除**（Apple App Store Review Guideline 5.1.1(v) / Google Play 兩者的上架硬性規定，SPEC §16 開放問題 6）。分兩步、Flutter 端依序呼叫：① `delete_account()` RPC——清理 `public` schema 業務資料、去識別化 `app_user`（row 保留、id 不變，見 ERD 設計備註 42），冪等（`{ success, already_deleted? }`）。② Edge Function `delete-auth-user`——驗證呼叫者 JWT 後呼叫官方 `auth.admin.deleteUser(id, shouldSoftDelete: true)`，只有這支 Function 持有 `service_role` key。呼叫端（Flutter）對步驟②做 2 次重試（1 秒/3 秒 backoff）後放棄，不論結果一律本地登出——步驟①已完成、`ACCOUNT_DELETED` 檢查已生效，殘留風險視窗很小，不需要背景重試佇列。 |
| 1.6 | `rpc: check_enrollment_reminder(p_degree_level)`（v1.21） | **NYCU 在校生年限軟性提醒（SPEC §2）**：僅當呼叫者信箱網域為 `nycu.edu.tw` 時才可能回 `true`；回傳布林值，由 `fn_seniority_reminder_needed(email, degree_level)` 計算（`fn_parse_nycu_enrollment_year(email)` 負責解析入學年，見 ERD 設計備註 45）。Flutter 端在 `complete_profile`（1.2）送出前呼叫，回 `true` 才跳一次性確認訊息，使用者確認後仍照常呼叫 1.2，**不阻擋註冊流程**。不落地存任何欄位，也不影響 1.2 本身的驗證邏輯。 |
| 1.7 | `rpc: get_my_badges()`（v1.29） | **Achievement Badges 成就徽章**：回傳 `[{ badge_code, earned }]`，四碼固定為 `FIRST_ACTIVITY`/`PUNCTUAL`/`GREAT_COMPANY`/`ENTHUSIASTIC_ORGANIZER`，皆從既有的 `user_reliability_event`/`rematch_vote`/`match_request` 即時計算，不新增任何表／欄位。補充（不取代）1.4 的可信度等級——刻意用累計數字而非近 30 天滾動窗，代表「曾經達成」的里程碑，跟可信度等級「近期表現」的性質不同。 |

錯誤碼：`INVALID_EMAIL_DOMAIN`、`PROFILE_INCOMPLETE`、`DEGREE_LEVEL_REQUIRED`、`NO_CONTACT_METHOD`、`ACCOUNT_DELETED`（v1.14，見 §0）

---

## 2. ActivityType / Location

| # | Endpoint | 說明 |
|---|---|---|
| 2.1 | `GET activity_type?status=eq.APPROVED`（PostgREST） | 公開類型清單。回傳包含 `default_min_participants`, `default_max_participants`, `group_size_step`（v1.5 / v1.6）、`description`（v1.10，前端「?」按鈕顯示的玩法說明，nullable）。<br>🟢 **選單計算規範（ERD 備註 22）**：前端建立 Request 選項卡時，若 `group_size_step` 非 null（如 `step=1` 或 `step=2`），從 min 到 max 按 step 算出的數值為唯一可選的離散人數選項；`group_size_step` 為 null 時才渲染為連續區間選單。 |
| 2.2 | `rpc: search_activity_type(query)` | 新增前的模糊比對/autocomplete（SPEC §5，防「羽球 vs 羽毛球」重複稀釋配對池）。 |
| 2.3 | `rpc: propose_activity_type(name)` | 流程：關鍵字黑名單預檢（命中即回 `NAME_BLACKLISTED`，不落庫）→ `PENDING` → admin 審核（於 Supabase Dashboard 一併設定 `default_duration_minutes`/`default_min_participants`/`default_max_participants`/`group_size_step`/`description`，v1.10 新增 `description`）。審核走 Supabase Dashboard/service role 查 `pending_review` view（v1.10，見下方審核管道說明），MVP 不做 admin API。 |
| 2.4 | `GET location?is_active=eq.true&status=eq.APPROVED&school=eq.{我的 school}&campus=eq.{選定 campus}`（PostgREST) | 固定地點下拉清單，依校分列（SPEC §1）；client 只顯示自己學校、已審核通過的清單，server 端最終由 3.1 的 `INVALID_CAMPUS_SCOPE` 把關。`status=eq.APPROVED` 為 v1.10 新增，排除提案中/被拒的地點；`campus=eq.{...}` 為 v1.11 新增（`location.campus`，見 ERD 備註 28），選定 Matching Scope 的 campus 後用來列出該範圍內的候選地點（供 6.4 `propose_activity_location` 用）。 |
| 2.5 | `rpc: propose_location(name, school, campus)`（v1.10，v1.11 新增 `campus` 參數） | 提議新地點，流程比照 2.3：`PENDING` → admin 審核。不做關鍵字黑名單預檢——地點名稱塞入違規字眼的難度較高，且 MVP 真正的把關是 admin 人工查 `pending_review` view（ERD 備註 26/27）再核准。`campus` 為必填（v1.11）：核准後的地點需要 `campus` 才能參與任何撮合，不補會產生無法使用的死地點。 |

錯誤碼：`NAME_BLACKLISTED`、`DUPLICATE_TYPE_NAME`、`DUPLICATE_LOCATION_NAME`（v1.10）、`INVALID_INPUT`（v1.14.1 補上文件：2.3 空白名稱 detail `NAME_REQUIRED`；2.5 空白名稱/校區 detail `NAME_REQUIRED`/`CAMPUS_REQUIRED`）

> 🟢 **審核管道（v1.10）**：`activity_type`/`location` 的 `PENDING` 審核共用同一張 `pending_review` view（UNION 兩表 `status = 'PENDING'` 的項目），admin 直接在 Supabase Studio 查詢並修改對應原表的 `status` 欄位，不新建任何 admin 專屬 API 或前端頁面（ERD 備註 27）。

---

## 3. MatchRequest（找人流程；只動 `match_request` 側）

> 🔴 **v1.9 移除**：原 `3.4 rpc: join_request(request_id)`（非邀請連結、直接加入他人 Request 的版本）已從本節移除，編號不遞補（3.5 起維持原編號）。產品自 v1.5 邀請連結機制上線後，就沒有任何「瀏覽/挑選他人 Request」的 UI 路徑（v1.5 變更紀錄：「v1 沒有 Friend entity、不存任何朋友關係資料」；核心設計是「盲配不挑人」）——加入他人 Request 的唯一合法方式是 3.8 `join_request_by_token`。這是 v1.5 之前的設計遺留、從未有對應 UI 路徑會呼叫它，不是漏實作；理由與更早移除 `create_request` 的 `invited_user_ids` 參數相同。詳見 SPEC.md v1.9 變更紀錄。

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 3.1 | `rpc: create_request(activity_type_id, campus, earliest_start, latest_start, min_participants, max_participants?, allow_downgrade)` | R1 | 🔴 **（v1.16）**`bucket` 參數移除，改由呼叫端直接傳入換算好的 `earliest_start`/`latest_start`（timestamptz）；時段桶（NOW/TODAY/TONIGHT/TOMORROW_AM 等）是 UI 層的呈現方式，換算邏輯移回前端，backend 只驗證範圍合法性（SPEC §4、v1.16 變更紀錄）：① `latest_start <= earliest_start` → `INVALID_INPUT` detail `LATEST_START_MUST_BE_AFTER_EARLIEST_START`；② `latest_start > now() + 24h` → `WINDOW_EXCEEDS_24H`；③ `latest_start < now()` → `INVALID_INPUT` detail `LATEST_START_IN_PAST`；`earliest_start` 不設下限（Matching Engine 用 `greatest()` 取實際 `start_time`，過早不影響正確性）。`min_participants >= 2`；`max_participants` 為 upper bound (null 則 fallback 至 `activity_type.default_max_participants`)。<br>🟢 **驗證規範**：① `min/max_participants` 計數**包含 owner 本人**。② 若 `group_size_step` 非 null，帶入的人數必須符合離散步階選項，否則回傳 `INVALID_GROUP_SIZE_OPTION`。③ **（v1.11）** `campus` 不再是精確地點 FK，而是 Matching Scope 的自由文字校區值；檢查 owner 的 `school` 底下是否存在至少一筆 `status='APPROVED'` 且 `campus` 相符的地點，否則回 `INVALID_CAMPUS_SCOPE`（SPEC §6/§7 同校隔離，取代 v1.10 及之前版本的 `SCHOOL_LOCATION_MISMATCH`；`school` 本身不對——目前 create_request 已不接受 `school` 參數，不會發生——才會是 `SCHOOL_LOCATION_MISMATCH`，見 3.8）。④ 僅建立 owner 本人的 Request（此時 `request_member` 只有 owner 一人）；邀請朋友加入一律透過 3.7 生成邀請連結，好友透過 3.8 加入，在 Matching Engine 掃描撮合前陸續完成組隊。精確地點（Activity Location）改成配對成立後才由參與者投票決定，見 6.4/6.5。 |
| 3.2 | `rpc: submit_request(request_id)` | R2 | 送出進 Queue。🟢 **驗證順序定案（deterministic，SPEC §6.3），任何未來重構都不能打亂**：① `UNAUTHORIZED`（未登入）② `USER_SUSPENDED`（停權中）③ `PROFILE_INCOMPLETE`（個人資料未完成）④ *(結構性檢查，載入 Request 本體)* `NOT_FOUND` / `REQUEST_NOT_OPEN` ⑤ **`ACTIVE_ACTIVITY_IN_PROGRESS`**（owner 名下有 `MATCHED`/`ONGOING` 的 Activity，v1.7 新增，見 SPEC §6.3——排在冷卻檢查之前，因為「活動還沒結束」是根源問題）⑥ **`REQUEST_COOLDOWN_ACTIVE`**（`app_user.next_request_allowed_at > now()`，v1.7 新增）⑦ 單一 `REQUESTING` 限制（`ALREADY_REQUESTING`）⑧ 24h 時間窗（`WINDOW_EXCEEDS_24H`）⑨ **新人低人數限制**（`min_participants ≤ 2` 且任一成員 `fn_is_new_user()` = true → `NEW_USER_LOW_HEADCOUNT`，SPEC §12.1）。 |
| 3.3 | `rpc: cancel_request(request_id)` | R5 | 配對成立前取消，不記 Reliability 事件。owner 專用；非 owner 成員請改用 3.5 `leave_request`。 |
| 3.5 | `rpc: leave_request(request_id)` | — | 非 owner 成員退出（`request_member.status → LEFT`）；配對成立前退出不記事件。owner 呼叫回 `FORBIDDEN`（應改用 3.3 `cancel_request`）；配對成立後（非 `DRAFT`/`REQUESTING`/`PENDING_CONFIRMATION`）回 `REQUEST_NOT_OPEN`，改走 6.3 `cancel_activity_participation`。 |
| 3.6 | `GET match_request`（PostgREST，RLS：owner 或成員） | — | 查自己的 Request 與狀態。 |
| 3.7 | `rpc: get_or_create_invite_link(request_id)` | — | **生成/取得專屬邀請連結 (v1.5)**：回傳 `invite_token`。生命週期依附本列 `status = 'REQUESTING'` 且未被主動撤銷（`revoked_at is null`），不另存到期時間（ERD 備註 18）。 |
| 3.8 | `rpc: join_request_by_token(invite_token)` | — | **透過邀請連結加入 Request (v1.5)**：已完成身份驗證的使用者帶入 `invite_token` 加入（本質為信任引導 Trust Bootstrap，不與 Friend 表綁定）。檢查：Token 未撤銷、未過期、未超過 `max_participants` 上限、通過新人低人數限制與同校隔離檢查。加入後新增 `request_member` 記錄。 |
| 3.9 | `rpc: revoke_invite_link(request_id)` | — | **撤銷邀請連結 (v1.5)**：僅 owner 可呼叫，設定 `revoked_at = now()`，使該 Token 立即失效。 |

錯誤碼：`ALREADY_REQUESTING`（單一 REQUESTING 限制）、`WINDOW_EXCEEDS_24H`、`NEW_USER_LOW_HEADCOUNT`（新人不可 ≤2 人局）、`INVALID_CAMPUS_SCOPE`（v1.11，`campus` 在 owner 的 `school` 底下無任何已核准地點，取代 v1.10 及之前版本 3.1 用的 `SCHOOL_LOCATION_MISMATCH`）、`SCHOOL_LOCATION_MISMATCH`（v1.11 起僅用於 3.8 `join_request_by_token` 的跨校加入檢查——學校本身不對，跟 `INVALID_CAMPUS_SCOPE` 語意分開，見 ERD 備註 34）、`INVALID_GROUP_SIZE_OPTION`（人數不符步階）、`INVITE_LINK_EXPIRED`（邀請連結已失效——🔴 v1.14.1 校對：不存在/已撤銷/已過期的 token 一律回這個碼，不單獨區分「已撤銷」，呼叫端的補救方式相同，故文件移除先前誤植的 `INVITE_LINK_REVOKED`）、`REQUEST_FULL`（已達人數上限）、`REQUEST_NOT_OPEN`、`USER_SUSPENDED`、`ACTIVE_ACTIVITY_IN_PROGRESS`（名下有進行中活動，v1.7）、`REQUEST_COOLDOWN_ACTIVE`（拒絕/晚取消觸發的 30 分鐘冷卻未過，v1.7）、`INVALID_INPUT`（v1.14.1 補上文件：活動類型不存在或未核准 detail `ACTIVITY_TYPE_NOT_FOUND_OR_NOT_APPROVED`；🔴 v1.16：`bucket` 移除後改為 3.1 `create_request` 的時間窗不合法，detail `LATEST_START_MUST_BE_AFTER_EARLIEST_START` 或 `LATEST_START_IN_PAST`）、`INVALID_MIN_PARTICIPANTS`（v1.14.1 補上文件：3.1 `min_participants < 2`）、`INVALID_MAX_PARTICIPANTS`（v1.14.1 補上文件：3.1 `max_participants < min_participants`）

---

## 4. Candidate Confirmation（PENDING_CONFIRMATION 候選確認流程；v1.4）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 4.1 | `rpc: get_pending_confirmation_status(request_id)` | — | **專用受控讀取 RPC（SECURITY DEFINER）**：給前端查詢當前候選配對進度。回傳 `{ pending_confirmation_id, status: PENDING\|CONFIRMED\|DECLINED\|TIMEOUT, confirm_window_expire_at }`。<br>🟢 **對稱不歸因原則（ERD 備註 16）**：RPC 僅傳回整體 `status`，**絕對不暴露**對方的個人選擇 (`CONFIRMED`/`DECLINED`/`NO_RESPONSE`)，避免任何一方判斷出是誰造成配對未成立。 |
| 4.2 | `rpc: respond_pending_confirmation(pending_confirmation_id, confirm: bool)` | PC1 / PC2 | 使用者在 10 分鐘 `CONFIRM_WINDOW` 內回應。🟢 **允許反悔（v1.7 澄清）**：窗口內可重複呼叫改變心意，覆寫先前的回應，不視為錯誤——過去版本文件曾列出 `ALREADY_RESPONDED` 錯誤碼，但 RPC 從未真正實作過這道擋，v1.7 正式移除，避免文件承諾不存在的行為。<br>🟢 **原子性與並發安全**：RPC **僅更新呼叫者自己的欄位**（`user_a_response` 或 `user_b_response`，設定為 `CONFIRMED` 或 `DECLINED`），並於同一 Transaction 內（利用 `UPDATE ... WHERE status = 'PENDING'` 或 `SELECT ... FOR UPDATE` 加鎖）原子性判定雙方回應結果：<br>① **若雙方皆為 CONFIRMED**：轉移至 **PC1**（`pending_confirmation.status → CONFIRMED`，建立 `Activity` + `activity_member` 並發送 `MATCH_SUCCESS` 通知）。<br>② **若任一方為 DECLINED**：轉移至 **PC2**（`pending_confirmation.status → DECLINED`；並由 RPC 或背景 Worker 執行 PC2 清理：寫入 `match_history_avoidance` 降權記錄、雙方 Request 無差別退回 Queue `REQUESTING`、發送無差別「配對未成立」通知）。**主動傳 `confirm=false` 的呼叫者另會被寫入 `app_user.next_request_allowed_at = now() + 30 分鐘`（v1.7 冷卻機制，SPEC §6.3；由背景 Worker 觸發的 `TIMEOUT` 不寫入此欄位，因為無法歸咎任何一方）**。 |
| 4.3 | `rpc: get_pending_confirmation_candidate_info(pending_confirmation_id)`（v1.22） | — | **專用受控讀取 RPC（SECURITY DEFINER）**：補上 SPEC §12.1.3「安全資訊卡」此前從未有對應資料源的落差。權限判準與 4.2 完全相同（呼叫者須為 `request_a`/`request_b` 其中一方的 owner）。回傳**對方**（非呼叫者自己）的 `{ display_name, avatar_url, school, department, degree_level, reliability_tier, completed_activity_count }`；`reliability_tier`/`completed_activity_count` 複用既有的 `fn_reliability_tier`/`user_reliability_event` ATTENDED 計數，口徑與 1.4 `get_my_reliability`、12.1.1 `fn_is_new_user` 一致。🟢 **不查詢、不回傳 `user_a_response`/`user_b_response`**：對稱不歸因原則（見 4.1）不受影響，這支 RPC 只補個人資料欄位，不是新增一條繞過不歸因設計的路徑。 |

錯誤碼：`CONFIRMATION_WINDOW_CLOSED`（10 分鐘已過，僅 4.2）、`NOT_FOUND`（detail `PENDING_CONFIRMATION_NOT_FOUND`——🔴 v1.14.1 校對：`pending_confirmation_id` 不存在時實際回這個碼，跟其他所有 lookup RPC 同一慣例，文件移除先前誤植、從未實作過的 `INVALID_PENDING_CONFIRMATION`；4.1/4.3 亦適用同一碼）、`FORBIDDEN`（detail `NOT_PARTY_TO_CONFIRMATION`，v1.14.1 補上文件：4.2 呼叫者既非 request_a 也非 request_b 的 owner；4.3 同一判準同一碼）

---

## 5. Downgrade（掛在 REQUESTING 內部）

| # | Endpoint | 說明 |
|---|---|---|
| 5.1 | `rpc: respond_downgrade(downgrade_request_id, agree: bool)` | 10 分鐘 `CONSENT_WINDOW` 內回應；過期回 `CONSENT_WINDOW_CLOSED`（超時=拒絕，Request 以原門檻回池，SPEC §8）。發起端是系統（背景任務 `fn_expire_requests()`，v1.12 起真正落地，見 §9），沒有使用者發起的 endpoint。<br>🟢 **驗證規範（ERD 備註 21）**：`target_size` 必須低於原 `min_participants`，由系統發起與回應 RPC 進行應用層比對。<br>🟢 **v1.12 起補上此前完全沒發過的 `DOWNGRADE_RESULT` 通知**：任一人 `DISAGREE` 立即向全體 `downgrade_consent` 成員發送（`status=REJECTED`）；全員 `AGREE` 的那一刻才發（`status=APPROVED`），部分同意時不提前發，比照 4.2 只在最終 PC1/PC2 轉移時才通知的既有模式。 |
| 5.2 | `GET downgrade_request`（PostgREST，RLS：被詢問成員） | 查進行中的降門檻詢問。 |

錯誤碼：`CONSENT_WINDOW_CLOSED`、`ALREADY_RESPONDED`

---

## 6. Activity（實際活動；只動 `activity` 側）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 6.1 | `GET activity` + `GET activity_member`（PostgREST，RLS：成員） | — | 我的活動、成員名單、`source_request_id` 來源。🔴 v1.11.1 修正一個 bug：兩表的 RLS SELECT policy 過去會觸發「infinite recursion detected in policy」（`activity_member` policy 自我參照），這個端點對 `authenticated` 角色實際上一直是 500，見 SPEC v1.11.1 變更紀錄第 7 條、ERD 設計備註 38。 |
| 6.1.1 | `rpc: get_activity_member_profiles(activity_id)`（v1.23） | — | **成員名單的個人資料補充出口**：`app_user` 的 `own_profile_select` RLS 只允許查自己，6.1 拿不到其他成員的 `school`/`department`/`degree_level`/可信度等級，這支 RPC 補上。呼叫者須為該活動 `JOINED` 成員（同 6.2 判準），否則 `NOT_ACTIVITY_MEMBER`。回傳該活動全體成員（不論 `JOINED`/`CANCELLED`，同 6.2 不過濾）的 `user_id`/`school`/`department`/`degree_level`/`reliability_tier`（複用 `fn_reliability_tier`）。刻意不含 `display_name`/`avatar_url`/`contacts`——6.2 已無條件回傳前兩者，避免兩支 RPC 重複欄位；前端依 `user_id` 合併兩支 RPC 的結果。這些欄位屬一般個人資料，不比照 `contacts` 加時效/再約閘門。 |
| 6.2 | `rpc: get_activity_contacts(activity_id)` | — | **聯絡方式唯一出口**（不走 RLS 直讀 `app_user.contact_*`）。規則（SPEC §11）：呼叫者是該活動成員，且（`now() < contact_visible_until`【以 Activity 的 `created_at` 起算 +24h，SPEC v1.1 變更 5】**或** 與對方互按過再約）。回各成員自選公開的聯絡方式。🔴 **v1.14.1 校對補充**：逾期或未達成互相再約條件時，該成員的 `contacts` 欄位回傳 `null`（HTTP 200），不是拋錯——client 一律先拿到成員名單再自行判斷 `contacts` 是否為 null，不需要 try/catch 一個常態情境。此規則跟活動的 `status`（`MATCHED`/`ONGOING`/`COMPLETED`/`CANCELLED`）無關，`COMPLETED`/`CANCELLED` 後的活動一樣照上述規則判斷，不額外加狀態閘門（活動結束後仍能看到彼此聯絡方式正是這支 RPC 存在的目的）。 |
| 6.3 | `rpc: cancel_activity_participation(activity_id)` | A5/A6 | 個別取消。🔴 **v1.14.1 補上驗證缺口**：活動須為 `MATCHED`/`ONGOING`（STATE_MACHINE.md A5/A6 本來就只定義這兩個來源狀態），否則回 `ACTIVITY_NOT_ACTIVE`（重用 6.6/6.7 既有的碼，同一個狀態閘門，不是新錯誤碼）。通過後 server 依時點記事件：開始前 ≥1h → `EARLY_CANCEL`（不計入記錄）；<1h 或已開始 → `LATE_CANCEL`（SPEC §10 處罰分級，**同時寫入 `app_user.next_request_allowed_at = now() + 30 分鐘`，v1.7 冷卻機制，SPEC §6.3；`EARLY_CANCEL` 不觸發**）。 |
| 6.4 | `rpc: propose_activity_location(activity_id, location_id, custom_name)`（v1.11，`custom_name` 為 v1.30 新增） | — | **提案 Activity Location 候選（SPEC §9.1）**：呼叫者須為該活動成員，且活動仍是 `MATCHED` 且 `activity_location_id` 尚未鎖定；`location_id`/`custom_name` 恰好給一個，都給或都不給回 `INVALID_INPUT`。給 `location_id` 時須屬於該活動的 `(school, campus)` 範圍內、`status='APPROVED'` 的地點（否則 `INVALID_CAMPUS_SCOPE`），跟 v1.11 行為相同。給 `custom_name`（v1.30，1~40 字，超出回 `INVALID_INPUT`）時**不做任何審核或範圍檢查**，直接建立僅該活動可見的候選，且不寫入 `location` 表——見 SPEC v1.30 變更紀錄。提案動作同時視為投給該候選一票；若該候選已存在（他人先提過同一 `location_id`，或同名——大小寫不敏感——的 `custom_name`），本次呼叫退化成投票，不視為錯誤。 |
| 6.5 | `rpc: vote_activity_location(activity_id, option_id)`（v1.11，v1.30 起參數由 `location_id` 改名 `option_id`） | — | **對既有候選投票（SPEC §9.1）**：呼叫者須為該活動成員，且活動仍是 `MATCHED` 且 `activity_location_id` 尚未鎖定；`option_id` 須是該活動既有的 `activity_location_option.id`（先前透過 6.4 建立），否則回 `NOT_FOUND`。一人一票，可改票（重複呼叫覆寫先前的投票）。得票最高者於 `start_time` 由背景任務 `fn_start_activities()` 鎖定，寫入 `activity.activity_location_id`（v1.30 起是 `activity_location_option.id`，不是 `location.id`——見下方 §9.1 備註）；同票取最早提案者勝出（見 SPEC §9.1、ERD 設計備註 31/32/46）。 |
| 6.6 | `rpc: update_meeting_point(activity_id, description)`（v1.11.1） | — | **更新集合地點（SPEC §9.2）**：呼叫者須為該活動 `JOINED` 成員，且活動 `status in (MATCHED, ONGOING)`；`description` 不可為空白。獨立於 `activity_location_id` 是否鎖定，append-only（不覆寫舊記錄，「目前集合點」＝取最新一筆）。同一人 2 分鐘內連續呼叫回 `MEETING_POINT_UPDATE_COOLDOWN`（`app_config.meeting_point_update_cooldown_minutes`，預設 2 分鐘）。成功後向該活動全體 `JOINED` 成員發送 `MEETING_POINT_UPDATED` 通知。 |
| 6.7 | `rpc: update_meeting_hint(activity_id, hint)`（v1.11.1） | — | **更新個人化見面提示（SPEC §9.2）**：呼叫者須為該活動 `JOINED` 成員，且活動 `status in (MATCHED, ONGOING)`；`hint` 最多 30 字（RPC 層 `INVALID_INPUT` + DB 層 CHECK 雙重防線），可傳空字串/空白清空。直接覆寫 `activity_member.meeting_hint`，不像 6.6 是 append-only 記錄，不觸發通知。 |
| 6.8 | `rpc: mark_arrived(activity_id)`（v1.24） | — | **Arrival Check「我到了」**：呼叫者須為該活動 `JOINED` 成員，且活動 `status in (MATCHED, ONGOING)`，否則分別回 `NOT_ACTIVITY_MEMBER`/`ACTIVITY_NOT_ACTIVE`（沿用 6.6/6.7 同一組閘門與碼）。覆寫 `activity_member.arrived_at`，單向（`null`→時間戳，無清空路徑）、冪等（已標記過重複呼叫回傳現有 row，不重複通知）。成功首次標記後向該活動**其餘**（不含自己）`JOINED` 成員發送 `MEMBER_ARRIVED` 通知，payload 含 `arrived_user_id`/`display_name`。 |
| 6.9 | `rpc: update_vibe_tags(activity_id, tags)`（v1.28） | — | **Vibe Tags 情境標籤**：閘門同 6.7（`JOINED` 成員 + `status in (MATCHED, ONGOING)`）。`tags` 最多 3 個、每個最多 20 字，超出回 `INVALID_INPUT` detail `TOO_MANY_TAGS`/`TAG_TOO_LONG`（陣列元素長度僅 RPC 層檢查，DB 層只有陣列長度上限的 CHECK，見遷移檔取捨說明）。直接覆寫 `activity_member.vibe_tags`（不像 6.6 append-only），空陣列正規化為 `null`，不觸發通知（同 6.7 的個人化欄位精神）。**刻意不用於配對邏輯**——matching engine 完全不讀這個欄位，只在配對成立後給成員互看，降低期待不一致的社交摩擦。 |

錯誤碼：`NOT_ACTIVITY_MEMBER`、`ACTIVITY_LOCATION_LOCKED`（v1.11，活動已鎖定候選地點或已開始，見 6.4/6.5）、`INVALID_CAMPUS_SCOPE`（v1.11，6.4 給 `location_id` 時該地點不屬於該活動的 `(school, campus)` 範圍）、`NOT_FOUND`（v1.11，6.5 投給一個尚不存在的候選 `option_id`）、`ACTIVITY_NOT_ACTIVE`（v1.11.1 起用於 6.6/6.7；v1.14.1 起 6.3 也重用同一個碼；v1.24 起 6.8、v1.28 起 6.9 亦重用，見上方各節說明）、`MEETING_POINT_UPDATE_COOLDOWN`（v1.11.1，6.6 冷卻中）、`INVALID_INPUT`（v1.11.1，6.6 空白描述 / 6.7 提示超過 30 字；v1.28，6.9 標籤數量/長度超限；v1.30，6.4 `location_id`/`custom_name` 沒有恰好給一個，或 `custom_name` 長度超過 40 字）

> 🔴 **v1.14.1 校對移除**：`CONTACT_EXPIRED`、`ACTIVITY_ALREADY_ENDED` 兩個碼從未被任何 RPC 實際 raise 過。前者的替代行為（`contacts` 回傳 `null`）已是合理設計，見上方 6.2 說明；後者拆成兩支 RPC 分別判斷——6.2 刻意不需要這個狀態閘門（見 6.2 說明），6.3 的真缺口已改用既有的 `ACTIVITY_NOT_ACTIVE` 補上（見上方 6.3 說明與 RPC_COVERAGE.md）。

---

## 7. 完成確認 / 再約

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 7.1 | `rpc: submit_completion_report(activity_id, result, absent_user_ids?)` | A3 | 三選一（SPEC §10）。🔴 **v1.14.1 補上驗證缺口**：活動須為 `ONGOING` 才能提交，否則回 `ACTIVITY_NOT_ENDED`（此前完全沒有狀態檢查，`MATCHED`/`COMPLETED`/`CANCELLED` 都能被提交）。`absent_user_ids` 僅 `result=REPORTED_ABSENT` 時必填，且限定該活動成員，否則回 `INVALID_ABSENT_TARGET`（此前完全沒有成員資格檢查）。每人一次（DB unique）。達 ≥50% 門檻時由本 RPC 內嵌觸發結算：多數決記 `NO_SHOW`／`ATTENDED`；2 人互咬不判；連續 3 次 No-show → 寫 `suspended_until`。 |
| 7.2 | `rpc: rematch_vote(activity_id, to_user_id)` | — | 按「👍 再約」。當對方也投過（雙向成立）→ 該兩人間聯絡方式永久保留（6.2 的判定來源），並各發通知。 |

錯誤碼：`ALREADY_REPORTED`、`INVALID_ABSENT_TARGET`（指認對象不在成員名單，v1.14.1 起真正落實）、`ACTIVITY_NOT_ENDED`（活動須為 `ONGOING`，v1.14.1 起真正落實）、`INVALID_INPUT`（v1.14.1 補上文件：7.2 `rematch_vote` 對自己投票 detail `CANNOT_VOTE_SELF`）

---

## 8. Notification

| # | Endpoint | 說明 |
|---|---|---|
| 8.1 | `GET notification`（PostgREST，RLS：own） | 收件匣，`payload` 帶 deep-link 所需 id。 |
| 8.2 | `PATCH notification`（RLS：own） | 標記已讀（`read_at`）。 |
| 8.3 | Push | FCM（SPEC §13），由背景任務發送，非 client API。 |

### 8.4 通知文案（v1.13 起開始定案，逐則補齊）

完整 `notification_event_type` 事件清單仍是 SPEC §16 開放問題 5 的一部分（其餘事件的文案細節待補）；目前只定案下面這兩則活動提醒相關的文案，因為 v1.13 新增 `ACTIVITY_UPCOMING` 時容易與既有 `ACTIVITY_REMINDER` 混淆，需要明確區分兩者的產品意圖與文字：

| event_type | 標題 | 內文 |
|---|---|---|
| `ACTIVITY_UPCOMING`（v1.13） | 活動快開始了 | 還有 {lead_minutes} 分鐘，記得看一下活動地點跟集合地點（`{lead_minutes}` 依 payload 動態帶入，見 §9「活動開始前提前提醒」） |
| `ACTIVITY_REMINDER` | 活動開始了 | 時間到囉，記得看一下活動地點跟集合地點再出發 |

---

## 9. 背景任務（非公開 API，pg_cron / Edge Function 排程）

| 任務 | 頻率 | 對應轉移 | 說明 |
|---|---|---|---|
| Matching Engine | 每分鐘 | R3a / R3b | 掃描 Queue 中時間窗重疊 + 地點相同的 Request 組合，達到 `min_participants` 貪婪成局：<br>① **若本次實際撮合人數 > 2**：直接建立 `Activity` (R3a)。<br>② **若本次實際撮合人數 ≤ 2**：建立 `pending_confirmation` 記錄，並將對應的 `match_request.status` 標記為 `PENDING_CONFIRMATION` (R3b)。 |
| PENDING_CONFIRMATION 超時與拒絕清理 | 每分鐘 | PC2 | 掃描 `confirm_window_expire_at < now()` 且為 `PENDING`、或已標記 `DECLINED` 的記錄：<br>① 將 `pending_confirmation.status` 設定為 `TIMEOUT` / `DECLINED`。<br>② 寫入 `match_history_avoidance` 降權記錄（正規化 `user_a_id < user_b_id`，避開 7 天）。<br>③ **雙方 Request 無差別退回 Queue (`REQUESTING`)** 重新進池（若 `latest_start` 已過期則自然轉為 `EXPIRED`）。<br>④ 🟢 **v1.12 起真正發送**：向雙方發送無差別 `MATCH_NOT_FORMED` 通知（不暴露對方回應與超時原因，payload 只帶收件者自己的 `request_id`）——此前這條規則只有本表格描述，`fn_cleanup_pending_confirmations()` 從未真的發過。 |
| Request 過期 | 每分鐘 | R4、Downgrade | 🟢 **v1.12 起第一次真正落地成 SQL**（`fn_expire_requests()`；先前完全沒有對應函式）：掃描 `status='REQUESTING'` 且 `latest_start < now()` 的 Request。①若這個 Request 自己的實際 JOINED 人數已達 `min_participants`（Matching Engine 一直沒找到可合併對象的邊緣情況），這輪不處理。②若曾經建立過 `downgrade_request`：仍在 `PENDING`/`APPROVED` → 不重複處理；已 `REJECTED`/`TIMEOUT`（問過一次沒談成）→ 不再問第二次，直接 `EXPIRED`。③從未問過，且 `allow_downgrade=true`、算出的 `target_size = greatest(2, 實際 JOINED 人數)` 有效、且 `latest_start` 過期還在 `app_config.downgrade_consent_window_minutes` 的寬限期內 → 建立 `downgrade_request` + 展開 `downgrade_consent`，向全體 `JOINED` 成員發送 `DOWNGRADE_REQUEST` 通知。④其餘情況 → `EXPIRED`，**不發通知**（EXPIRED 是被動的「什麼都沒發生」結果，不是需要打斷使用者的失敗事件；本輪也沒有為此新增 `notification_event_type` 值的預算，見 SPEC.md §9 State Machine 一節）。 |
| Downgrade 超時 | 每分鐘 | — | 🟢 **v1.12 起第一次真正落地成 SQL**（`fn_expire_downgrades()`；先前完全沒有對應函式）：`downgrade_request.status='PENDING'` 且 `expire_at` 已過 → `TIMEOUT`（超時視為拒絕，SPEC §8）。`match_request` 全程沒離開過 `REQUESTING`（STATE_MACHINE.md「Downgrade 子流程」），這裡不動它的狀態或門檻。向全體 `downgrade_consent` 成員發送 `DOWNGRADE_RESULT`（`status=TIMEOUT`）通知。 |
| Activity 開始 | 每分鐘 | A2 | 🟢 **v1.11 起第一次真正落地成 SQL**（`fn_start_activities()`；先前只有本表格描述，沒有對應函式，見 `app/lib/rpc/RPC_COVERAGE.md`）：`start_time` 已到 →（若 `activity_location_id` 仍為 `NULL`）先依得票數鎖定 Activity Location（同票取最早提案者，零候選則維持 `NULL`，見 SPEC §9.1）→ `ONGOING`；發送 `ACTIVITY_REMINDER` 通知。 |
| Activity Location 零候選提醒（v1.11） | 每分鐘 | — | `fn_remind_missing_location_candidates()`：`status='MATCHED'` 且 `start_time` 在 `app_config.location_reminder_lead_minutes`（預設 30 分鐘）內、仍無任何 `activity_location_option` → 向全體成員發送 `LOCATION_NOT_YET_PROPOSED` 通知；去重靠查詢 `notification` 表本身是否已發過同一活動同一事件，不另存欄位。 |
| Activity 超時完成 | 每小時 | A4 | 🟢 **v1.12 起第一次真正落地成 SQL**（`fn_complete_activities()`；先前完全沒有對應函式）：`status='ONGOING'` 且 `start_time + 24h` 已過 → 強制 `COMPLETED`，不做 No-show 判定、不記任何事件、不發通知（靜默 fallback）。不需要重新計算完成確認法定人數門檻——`submit_completion_report` 一旦達標當下就已經同步轉移為 `COMPLETED`（見 7.1），兩條路徑天然互斥，不會重複處理。 |
| 結束提醒 | 每 15 分鐘 | — | 🟢 **v1.12 起第一次真正落地成 SQL**（`fn_remind_completions()`；先前完全沒有對應函式）：`status='ONGOING'` 且 `estimated_end_time` 已過、且尚未發過 `COMPLETE_CONFIRMATION` → 向全體 `JOINED` 成員發送 `COMPLETE_CONFIRMATION`；去重靠查詢 `notification` 表本身，同 Activity Location 零候選提醒的既有模式。 |
| 活動開始前提前提醒（v1.13） | 每分鐘 | — | 🟢 **v1.13 新增**（`fn_remind_upcoming_activities()`）：掃描 `status='MATCHED'` 且 `start_time` 落在 `app_config.activity_reminder_lead_minutes_list`（預設 `{30,10}`，即 30 分鐘前 + 10 分鐘前兩個時間點）任一個時間點內的 Activity，向全體 `JOINED` 成員發送新事件 `ACTIVITY_UPCOMING`（跟「已經開始」的 `ACTIVITY_REMINDER` 區分，文案不同見 §8.4）；payload 帶 `lead_minutes` 供前端組文案。每個設定的時間點各自獨立掃描、獨立去重——去重鍵是 `(activity_id, lead_minutes)`，同一活動的 30 分鐘與 10 分鐘提醒是兩則獨立通知，查詢 `notification` 表本身即可，不另存欄位（同 Activity Location 零候選提醒的既有模式）。 |

---

## 10. 覆蓋檢查（SPEC / ERD 規則 ↔ API 落點）

| SPEC / ERD 規則 | API 落點 |
|---|---|
| §2 網域驗證（雙校） | 1.1 + DB CHECK |
| §2 school 自動判定、不讓 user 選 | 1.2 server 端 mapping + DB CHECK |
| §2 profile 硬門檻 + degree_level 必填 (v1.4) | 1.2 + 3.2/3.8 前置檢查 + DB CHECK |
| §2 `bio` / `department` 選填、不進配對邏輯 (v1.4) | 1.2/1.3（無門檻檢查）+ ERD 無 NOT NULL |
| §5 activity_type 人數選單預設與步階 (v1.5/v1.6) | 2.1 描述與 3.1 步階驗證 (`INVALID_GROUP_SIZE_OPTION`) |
| §6/§7 配對池同校隔離 | 3.1 的 `SCHOOL_LOCATION_MISMATCH` + location 的 school 歸屬 |
| §6 單一 REQUESTING | 3.2 + partial unique index |
| §6.1 / §16 邀請連結與信任引導 (v1.5) | 3.7 / 3.8 / 3.9 (Token 產生、受控加入、主動撤銷) |
| §7/§12.1 新人低人數限制 | 3.2 / 3.8 的 `NEW_USER_LOW_HEADCOUNT` |
| §8 Downgrade 全套 | 5.1 + 背景任務 |
| §9 兩張狀態圖分離 | §3 只動 request、§6 只動 activity 的 endpoint 邊界 |
| §10 多數決 / 2 人互咬 / 停權 | 7.1 結算邏輯 |
| §11 聯絡方式 24h + 再約永久保留 | 6.2 + 7.2 |
| §12 Reliability 即時 query | 1.4 |
| §12.1 / ERD 備註 16 PENDING_CONFIRMATION 與不歸因設計 (v1.4) | 4.1 / 4.2 / §9 排程 (專用受控 RPC、PC2 雙方對稱無差別退回 Queue) |
| §6.3 活動進行中鎖定 Request (v1.7) | 3.2 的 `ACTIVE_ACTIVITY_IN_PROGRESS` |
| §6.3 拒絕/晚取消 30 分鐘冷卻 (v1.7) | 3.2 的 `REQUEST_COOLDOWN_ACTIVE` + 4.2 `confirm=false` 分支 + 6.3 `LATE_CANCEL` 分支寫入 `next_request_allowed_at` |
| §6.3 `submit_request` 驗證順序定案 (v1.7) | 3.2 全文 |
| §6/§7 Matching Scope 改成 (school, campus) 範圍匹配 (v1.11) | 3.1 的 `INVALID_CAMPUS_SCOPE` + `fn_run_matching_engine` merge 條件 |
| §9.1 Activity Location 投票機制 (v1.11) | 6.4 / 6.5 + §9 背景任務「Activity 開始」`fn_start_activities()` |
| §9.1 零候選地點不代選、改發提醒 (v1.11) | §9 背景任務「Activity Location 零候選提醒」`fn_remind_missing_location_candidates()` |
| §9.2 Meeting Point / Meeting Hint，獨立於 activity_location_id 是否鎖定 (v1.11.1) | 6.6 / 6.7 |
| §9 八個背景任務全數首次落地成 SQL (v1.12) | §9「Request 過期」`fn_expire_requests()` / 「Downgrade 超時」`fn_expire_downgrades()` / 「Activity 超時完成」`fn_complete_activities()` / 「結束提醒」`fn_remind_completions()`；並補齊 5.1 `respond_downgrade` 的 `DOWNGRADE_RESULT` 與「PENDING_CONFIRMATION 超時與拒絕清理」的 `MATCH_NOT_FORMED` 兩處此前缺漏的通知觸發點 |
| 活動開始前提前提醒，可調多時間點 (v1.13) | §9「活動開始前提前提醒」`fn_remind_upcoming_activities()` + 新事件 `ACTIVITY_UPCOMING` + `app_config.activity_reminder_lead_minutes_list` + §8.4 文案 |
| App 內建帳號刪除，Apple/Google 上架硬性規定 (v1.14) | 1.5 `delete_account()` + Edge Function `delete-auth-user` + `app_user.deleted_at` + 21 支 RPC 的 `ACCOUNT_DELETED` 檢查（見 §0）+ ERD 設計備註 42 |
| §12.1.5 使用者主動封鎖，永久、單方、可自行解除 (v1.17) | §11 `block_user`/`unblock_user` + `fn_run_matching_engine` 新增獨立檢查 + ERD 設計備註 43 |
| §12.1.6 檢舉機制，人工審核不做自動懲罰 (v1.18) | §11 `submit_report` + ERD 設計備註 44 |
| 新手上手引導已讀時間戳 (v1.20，`docs/UI_PLAN.md` §11.1) | 1.3 `PATCH app_user` 的 `onboarding_seen_at` 欄位，不另開 RPC |
| §2 NYCU 在校生年限軟性提醒，僅提醒不擋門 (v1.21) | 1.6 `check_enrollment_reminder` + ERD 設計備註 45 |

---

## 11. 安全機制（封鎖／檢舉；v1.17/v1.18）

| # | Endpoint | 說明 |
|---|---|---|
| 11.1 | `rpc: block_user(p_blocked_id, p_reason?)` | **單方面封鎖（SPEC §12.1.5）**：冪等，重複呼叫只覆寫 `p_reason`。拒絕自我封鎖（`INVALID_INPUT` detail `CANNOT_BLOCK_SELF`）與不存在的對象（`NOT_FOUND` detail `BLOCKED_USER_NOT_FOUND`）。不檢查 `suspended_until`——封鎖是自我保護行為，停權中的使用者仍應能封鎖騷擾自己的人。生效後只影響 Matching Engine 未來的撮合（`fn_run_matching_engine` 新增獨立檢查，不與 `match_history_avoidance` 共用程式碼，見 ERD 設計備註 43），不影響任何進行中的活動。 |
| 11.2 | `rpc: unblock_user(p_blocked_id)` | 解除封鎖，冪等（找不到記錄也視為成功）。 |
| 11.3 | `GET user_block?blocker_id=eq.{自己}`（PostgREST，RLS：`blocker_id = auth.uid()`） | 查自己的封鎖清單。**被封鎖方永遠查不到自己被封鎖的記錄**（無 RLS policy 開放給 `blocked_id`），這是功能設計的核心前提，不是漏做。 |
| 11.4 | `rpc: submit_report(category, reported_user_id?, reported_activity_id?, detail?)`（v1.18） | **檢舉使用者或活動（SPEC §12.1.6）**：`reported_user_id`/`reported_activity_id` 至少一項非 null，否則回 `INVALID_INPUT` detail `REPORT_TARGET_REQUIRED`。`category` 為 `SPAM`\|`HARASSMENT`\|`OTHER`。審核走 Supabase Studio 人工查 `status='PENDING'`（比照 ERD 備註 27 `pending_review` view 的既有慣例），MVP 不做 admin API；人工判斷後可視情況手動更新對應使用者既有的 `suspended_until`，不新增獨立懲罰機制。 |
| 11.5 | `GET report?reporter_id=eq.{自己}`（PostgREST，RLS：`reporter_id = auth.uid()`）（v1.18） | 查自己送出的檢舉記錄；其餘使用者（含被檢舉方）皆查不到。 |

錯誤碼：`INVALID_INPUT`（detail `CANNOT_BLOCK_SELF` / `REPORT_TARGET_REQUIRED`）、`NOT_FOUND`（detail `BLOCKED_USER_NOT_FOUND`）

---

## 12. 意見回饋（v1.25）

| # | Endpoint | 說明 |
|---|---|---|
| 12.1 | `rpc: submit_feedback(message, activity_id?, app_version?, device_info?)` | **送出意見回饋（SPEC v1.25）**：`message` 去頭尾空白後長度需在 1–2000 字，否則 `INVALID_INPUT` detail `MESSAGE_REQUIRED`/`MESSAGE_TOO_LONG`。寫入 `feedback` 表，**不檢查 `activity_id` 是否真的跟呼叫者有關**（同 11.4 對 `reported_activity_id` 的既有處理，純屬客服排查用的情境資訊，不是權限邊界）。 |
| 12.2 | `GET feedback?user_id=eq.{自己}`（PostgREST，RLS：`user_id = auth.uid()`） | 查自己送出的回饋記錄；其餘使用者查不到。 |
| 12.3 | Edge Function `send-feedback-email` | **非公開 API**，由 Flutter 端在 12.1 成功後盡力呼叫（失敗不影響 12.1 的成功狀態）。只接受 `{ feedback_id }`，信件內容由 Function 自己用 service_role 重新查表組出，並驗證該筆記錄的 `user_id` 等於呼叫者自己。透過 Resend 寄到 `FEEDBACK_EMAIL_TO`（Supabase secret，非 Flutter `.env`）。 |

錯誤碼：`INVALID_INPUT`（detail `MESSAGE_REQUIRED` / `MESSAGE_TOO_LONG`）

---

## 13. 首頁氣氛指標（Campus Activity Pulse；v1.26）

| # | Endpoint | 說明 |
|---|---|---|
| 13.1 | `rpc: get_campus_pulse(school, campus)` | **匿名聚合統計**：回傳該 `(school, campus)` 底下每個 `activity_type` 目前 `REQUESTING` 中的 Request 數量。刻意不透露任何一筆 Request 的擁有者/時間窗/其他細節——`match_request` 的 RLS（`my_requests_select`）本來就只放行 owner/成員自己讀取（盲配設計的核心邊界，見 SPEC §11），這支 RPC 只回傳聚合計數，不違背該邊界。前端輪詢（30 秒一次），刻意不用 Realtime——把 `match_request` 整張表加進 publication 會讓 client 收到逐筆新增/消失事件，等於間接洩漏比聚合數字更細的時間點資訊。 |

無專屬錯誤碼（`UNAUTHORIZED` 沿用全域慣例）。

---

## 14. 提醒訂閱（Alert Subscription；v1.27）

| # | Endpoint | 說明 |
|---|---|---|
| 14.1 | `rpc: subscribe_activity_alert(activity_type_id, school, campus, lookahead_hours)` | **訂閱「這個類型/校區有新機會就通知我」**：`lookahead_hours` 限制 1–24，超出範圍回 `INVALID_INPUT` detail `LOOKAHEAD_HOURS_OUT_OF_RANGE`；`activity_type_id` 不存在回 `NOT_FOUND` detail `ACTIVITY_TYPE_NOT_FOUND`。同一使用者同時最多 5 筆有效（`expires_at > now()`）訂閱，超過回 `TOO_MANY_ALERT_SUBSCRIPTIONS`。 |
| 14.2 | `rpc: unsubscribe_activity_alert(subscription_id)` | 冪等取消，找不到（含不屬於自己的）也視為成功。 |
| 14.3 | `GET activity_alert_subscription?user_id=eq.{自己}`（PostgREST，RLS：`user_id = auth.uid()`） | 查自己的有效訂閱清單；其餘使用者查不到。 |

觸發點：`submit_request`（R2 `DRAFT → REQUESTING`）成功後，查符合 `(activity_type_id, school, campus)` 且 `expires_at > now()` 的訂閱，逐一發 `ALERT_TRIGGERED` 通知（不通知訂閱者自己剛送出的那筆），不消耗訂閱、同一筆訂閱在效期內可能觸發多次。payload 只帶 `activity_type_id`/`school`/`campus`，不帶 `request_id`（同 §13.1 的聚合、不指名精神）。

錯誤碼：`INVALID_INPUT`（detail `LOOKAHEAD_HOURS_OUT_OF_RANGE`）、`NOT_FOUND`（detail `ACTIVITY_TYPE_NOT_FOUND`）、`TOO_MANY_ALERT_SUBSCRIPTIONS`
