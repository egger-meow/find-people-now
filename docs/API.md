# API Endpoint Spec — 校園活動配對 App（派生自 SPEC v1.7）

> 本文件由 [SPEC.md](SPEC.md) 推導，建立在 [ERD.md](ERD.md) v1.7 與 [STATE_MACHINE.md](STATE_MACHINE.md) 定案之上。若與 SPEC 衝突，先改 SPEC。

## 0. 總約定

- **後端形態**：Supabase。純讀取走 PostgREST（RLS 已在 migration 定義）；**所有狀態轉移一律走 RPC**（`security definer` Postgres function，經 `supabase.rpc()` 呼叫），client 不直接 update 狀態欄位。轉移的合法性以 [STATE_MACHINE.md](STATE_MACHINE.md) 為準（編號 R1–R5、PC1–PC2、A1–A6）。
- **RLS 專用受控存取**：`pending_confirmation` 與 `match_history_avoidance` 兩張表在 DB 層故意「啟用 RLS 但不安裝 SELECT Policy」，防止使用者直接讀取敏感資料。前端查詢候選配對狀態必須透過特定的 `SECURITY DEFINER` RPC（如 4.1 `get_pending_confirmation_status`），僅透露整體 `status`，嚴格隔離個案回應明細（落實 ERD 設計備註 16）。
- **驗證**：所有呼叫需 Supabase Auth JWT（信箱 OTP 登入）。`auth.uid()` 即操作者，request body 不帶 `user_id`。
- **錯誤格式（v1.7 修正）**：RPC 以 `raise exception using message = '<CODE>'`（需要更細節的子原因時另加 `detail = '<detail>'`）回傳；下表的「錯誤碼」即為 `message` 的值，PostgREST 會將其映射到回應 JSON 的 `message` 欄位，client 應以此欄位比對錯誤碼。🔴 **不使用 `errcode = '<CODE>'`**：PL/pgSQL 的 `errcode` 只接受標準 5 碼 SQLSTATE 或內建的 condition name，塞入任意自訂字串（如 `'UNAUTHORIZED'`）會在 `raise` 當下直接拋出 `unrecognized exception condition`，蓋掉原本要回傳的錯誤，導致這裡列出的所有錯誤碼實際上從未真正生效過；v1.7 已修正全部 6 個 RPC migration 檔案的 65 處呼叫。
- **停權檢查**：`suspended_until > now()` 的使用者呼叫任何寫入類 RPC 一律回 `USER_SUSPENDED`。

---

## 1. Auth / Profile

| # | Endpoint | 說明 |
|---|---|---|
| 1.1 | `auth.signInWithOtp({ email })` | Supabase 內建。前端先擋非 `@nycu.edu.tw` / `@nthu.edu.tw`；DB 端 `app_user.email` CHECK 為最終防線（SPEC §2：完整雙校網域比對，非 `.edu.tw` 後綴）。 |
| 1.2 | `rpc: complete_profile(display_name, avatar_url, degree_level, department?, gender?, bio?, contact_ig?, contact_line?, contact_discord?)` | 註冊硬性門檻（SPEC §2, v1.4）：`avatar_url` 必填 + `degree_level` (enum `UNDERGRAD\|MASTER\|PHD`) 必選 + 三項聯絡方式至少一項。`bio` 與 `department` 選填、不卡門檻。未完成必填項前所有 Request 類 RPC 回 `PROFILE_INCOMPLETE`。**`school` 不是參數**——由 email 網域 mapping（`nycu.edu.tw → NYCU`、`nthu.edu.tw → NTHU`）在 server 端寫入，DB CHECK 保證與網域一致（SPEC §2：不讓使用者自選）。 |
| 1.3 | `PATCH app_user`（PostgREST，RLS：own row） | 更新個人資料（含 `bio`, `department`）；DB CHECK 保證改完仍滿足硬性門檻與必填約束。 |
| 1.4 | `rpc: get_my_reliability()` | 回 `{ tier: TRUSTED\|NORMAL\|NEW, is_new_user: bool }`，即時由 `fn_reliability_tier` / `fn_is_new_user` 計算（SPEC §12：不存分數欄位）。 |

錯誤碼：`INVALID_EMAIL_DOMAIN`、`PROFILE_INCOMPLETE`、`DEGREE_LEVEL_REQUIRED`、`NO_CONTACT_METHOD`

---

## 2. ActivityType / Location

| # | Endpoint | 說明 |
|---|---|---|
| 2.1 | `GET activity_type?status=eq.APPROVED`（PostgREST） | 公開類型清單。回傳包含 `default_min_participants`, `default_max_participants`, `group_size_step`（v1.5 / v1.6）。<br>🟢 **選單計算規範（ERD 備註 22）**：前端建立 Request 選項卡時，若 `group_size_step` 非 null（如 `step=1` 或 `step=2`），從 min 到 max 按 step 算出的數值為唯一可選的離散人數選項；`group_size_step` 為 null 時才渲染為連續區間選單。 |
| 2.2 | `rpc: search_activity_type(query)` | 新增前的模糊比對/autocomplete（SPEC §5，防「羽球 vs 羽毛球」重複稀釋配對池）。 |
| 2.3 | `rpc: propose_activity_type(name)` | 流程：關鍵字黑名單預檢（命中即回 `NAME_BLACKLISTED`，不落庫）→ `PENDING` → admin 審核。審核走 Supabase Dashboard/service role，MVP 不做 admin API。 |
| 2.4 | `GET location?is_active=eq.true&school=eq.{我的 school}`（PostgREST) | 固定地點下拉清單，依校分列（SPEC §1）；client 只顯示自己學校的清單，server 端最終由 3.1 的 `SCHOOL_LOCATION_MISMATCH` 把關。 |

錯誤碼：`NAME_BLACKLISTED`、`DUPLICATE_TYPE_NAME`

---

## 3. MatchRequest（找人流程；只動 `match_request` 側）

> 🔴 **v1.9 移除**：原 `3.4 rpc: join_request(request_id)`（非邀請連結、直接加入他人 Request 的版本）已從本節移除，編號不遞補（3.5 起維持原編號）。產品自 v1.5 邀請連結機制上線後，就沒有任何「瀏覽/挑選他人 Request」的 UI 路徑（v1.5 變更紀錄：「v1 沒有 Friend entity、不存任何朋友關係資料」；核心設計是「盲配不挑人」）——加入他人 Request 的唯一合法方式是 3.8 `join_request_by_token`。這是 v1.5 之前的設計遺留、從未有對應 UI 路徑會呼叫它，不是漏實作；理由與更早移除 `create_request` 的 `invited_user_ids` 參數相同。詳見 SPEC.md v1.9 變更紀錄。

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 3.1 | `rpc: create_request(activity_type_id, campus_location_id, bucket, min_participants, max_participants?, allow_downgrade)` | R1 | `bucket ∈ {NOW, TODAY, TONIGHT, TOMORROW_AM}` 換算成 `earliest_start/latest_start`（SPEC §4）。`min_participants >= 2`；`max_participants` 為 upper bound (null 則 fallback 至 `activity_type.default_max_participants`)。<br>🟢 **驗證規範**：① `min/max_participants` 計數**包含 owner 本人**。② 若 `group_size_step` 非 null，帶入的人數必須符合離散步階選項，否則回傳 `INVALID_GROUP_SIZE_OPTION`。③ 檢查 `campus_location_id` 屬於 owner 的 `school`，否則回 `SCHOOL_LOCATION_MISMATCH`（SPEC §6/§7 同校隔離）。④ 僅建立 owner 本人的 Request（此時 `request_member` 只有 owner 一人）；邀請朋友加入一律透過 3.7 生成邀請連結，好友透過 3.8 加入，在 Matching Engine 掃描撮合前陸續完成組隊。 |
| 3.2 | `rpc: submit_request(request_id)` | R2 | 送出進 Queue。🟢 **驗證順序定案（deterministic，SPEC §6.3），任何未來重構都不能打亂**：① `UNAUTHORIZED`（未登入）② `USER_SUSPENDED`（停權中）③ `PROFILE_INCOMPLETE`（個人資料未完成）④ *(結構性檢查，載入 Request 本體)* `NOT_FOUND` / `REQUEST_NOT_OPEN` ⑤ **`ACTIVE_ACTIVITY_IN_PROGRESS`**（owner 名下有 `MATCHED`/`ONGOING` 的 Activity，v1.7 新增，見 SPEC §6.3——排在冷卻檢查之前，因為「活動還沒結束」是根源問題）⑥ **`REQUEST_COOLDOWN_ACTIVE`**（`app_user.next_request_allowed_at > now()`，v1.7 新增）⑦ 單一 `REQUESTING` 限制（`ALREADY_REQUESTING`）⑧ 24h 時間窗（`WINDOW_EXCEEDS_24H`）⑨ **新人低人數限制**（`min_participants ≤ 2` 且任一成員 `fn_is_new_user()` = true → `NEW_USER_LOW_HEADCOUNT`，SPEC §12.1）。 |
| 3.3 | `rpc: cancel_request(request_id)` | R5 | 配對成立前取消，不記 Reliability 事件。owner 專用；非 owner 成員請改用 3.5 `leave_request`。 |
| 3.5 | `rpc: leave_request(request_id)` | — | 非 owner 成員退出（`request_member.status → LEFT`）；配對成立前退出不記事件。owner 呼叫回 `FORBIDDEN`（應改用 3.3 `cancel_request`）；配對成立後（非 `DRAFT`/`REQUESTING`/`PENDING_CONFIRMATION`）回 `REQUEST_NOT_OPEN`，改走 6.3 `cancel_activity_participation`。 |
| 3.6 | `GET match_request`（PostgREST，RLS：owner 或成員） | — | 查自己的 Request 與狀態。 |
| 3.7 | `rpc: get_or_create_invite_link(request_id)` | — | **生成/取得專屬邀請連結 (v1.5)**：回傳 `invite_token`。生命週期依附本列 `status = 'REQUESTING'` 且未被主動撤銷（`revoked_at is null`），不另存到期時間（ERD 備註 18）。 |
| 3.8 | `rpc: join_request_by_token(invite_token)` | — | **透過邀請連結加入 Request (v1.5)**：已完成身份驗證的使用者帶入 `invite_token` 加入（本質為信任引導 Trust Bootstrap，不與 Friend 表綁定）。檢查：Token 未撤銷、未過期、未超過 `max_participants` 上限、通過新人低人數限制與同校隔離檢查。加入後新增 `request_member` 記錄。 |
| 3.9 | `rpc: revoke_invite_link(request_id)` | — | **撤銷邀請連結 (v1.5)**：僅 owner 可呼叫，設定 `revoked_at = now()`，使該 Token 立即失效。 |

錯誤碼：`ALREADY_REQUESTING`（單一 REQUESTING 限制）、`WINDOW_EXCEEDS_24H`、`NEW_USER_LOW_HEADCOUNT`（新人不可 ≤2 人局）、`SCHOOL_LOCATION_MISMATCH`（地點不屬於自己學校）、`INVALID_GROUP_SIZE_OPTION`（人數不符步階）、`INVITE_LINK_REVOKED`（邀請連結已撤銷）、`INVITE_LINK_EXPIRED`（邀請連結已失效）、`REQUEST_FULL`（已達人數上限）、`REQUEST_NOT_OPEN`、`USER_SUSPENDED`、`ACTIVE_ACTIVITY_IN_PROGRESS`（名下有進行中活動，v1.7）、`REQUEST_COOLDOWN_ACTIVE`（拒絕/晚取消觸發的 30 分鐘冷卻未過，v1.7）

---

## 4. Candidate Confirmation（PENDING_CONFIRMATION 候選確認流程；v1.4）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 4.1 | `rpc: get_pending_confirmation_status(request_id)` | — | **專用受控讀取 RPC（SECURITY DEFINER）**：給前端查詢當前候選配對進度。回傳 `{ pending_confirmation_id, status: PENDING\|CONFIRMED\|DECLINED\|TIMEOUT, confirm_window_expire_at }`。<br>🟢 **對稱不歸因原則（ERD 備註 16）**：RPC 僅傳回整體 `status`，**絕對不暴露**對方的個人選擇 (`CONFIRMED`/`DECLINED`/`NO_RESPONSE`)，避免任何一方判斷出是誰造成配對未成立。 |
| 4.2 | `rpc: respond_pending_confirmation(pending_confirmation_id, confirm: bool)` | PC1 / PC2 | 使用者在 10 分鐘 `CONFIRM_WINDOW` 內回應。🟢 **允許反悔（v1.7 澄清）**：窗口內可重複呼叫改變心意，覆寫先前的回應，不視為錯誤——過去版本文件曾列出 `ALREADY_RESPONDED` 錯誤碼，但 RPC 從未真正實作過這道擋，v1.7 正式移除，避免文件承諾不存在的行為。<br>🟢 **原子性與並發安全**：RPC **僅更新呼叫者自己的欄位**（`user_a_response` 或 `user_b_response`，設定為 `CONFIRMED` 或 `DECLINED`），並於同一 Transaction 內（利用 `UPDATE ... WHERE status = 'PENDING'` 或 `SELECT ... FOR UPDATE` 加鎖）原子性判定雙方回應結果：<br>① **若雙方皆為 CONFIRMED**：轉移至 **PC1**（`pending_confirmation.status → CONFIRMED`，建立 `Activity` + `activity_member` 並發送 `MATCH_SUCCESS` 通知）。<br>② **若任一方為 DECLINED**：轉移至 **PC2**（`pending_confirmation.status → DECLINED`；並由 RPC 或背景 Worker 執行 PC2 清理：寫入 `match_history_avoidance` 降權記錄、雙方 Request 無差別退回 Queue `REQUESTING`、發送無差別「配對未成立」通知）。**主動傳 `confirm=false` 的呼叫者另會被寫入 `app_user.next_request_allowed_at = now() + 30 分鐘`（v1.7 冷卻機制，SPEC §6.3；由背景 Worker 觸發的 `TIMEOUT` 不寫入此欄位，因為無法歸咎任何一方）**。 |

錯誤碼：`CONFIRMATION_WINDOW_CLOSED`（10 分鐘已過）、`INVALID_PENDING_CONFIRMATION`

---

## 5. Downgrade（掛在 REQUESTING 內部）

| # | Endpoint | 說明 |
|---|---|---|
| 5.1 | `rpc: respond_downgrade(downgrade_request_id, agree: bool)` | 10 分鐘 `CONSENT_WINDOW` 內回應；過期回 `CONSENT_WINDOW_CLOSED`（超時=拒絕，Request 以原門檻回池，SPEC §8）。發起端是系統（Matching Engine），沒有使用者發起的 endpoint。<br>🟢 **驗證規範（ERD 備註 21）**：`target_size` 必須低於原 `min_participants`，由系統發起與回應 RPC 進行應用層比對。 |
| 5.2 | `GET downgrade_request`（PostgREST，RLS：被詢問成員） | 查進行中的降門檻詢問。 |

錯誤碼：`CONSENT_WINDOW_CLOSED`、`ALREADY_RESPONDED`

---

## 6. Activity（實際活動；只動 `activity` 側）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 6.1 | `GET activity` + `GET activity_member`（PostgREST，RLS：成員） | — | 我的活動、成員名單、`source_request_id` 來源。 |
| 6.2 | `rpc: get_activity_contacts(activity_id)` | — | **聯絡方式唯一出口**（不走 RLS 直讀 `app_user.contact_*`）。規則（SPEC §11）：呼叫者是該活動成員，且（`now() < contact_visible_until`【以 Activity 的 `created_at` 起算 +24h，SPEC v1.1 變更 5】**或** 與對方互按過再約）。回各成員自選公開的聯絡方式。 |
| 6.3 | `rpc: cancel_activity_participation(activity_id)` | A5/A6 | 個別取消。server 依時點記事件：開始前 ≥1h → `EARLY_CANCEL`（不計入記錄）；<1h 或已開始 → `LATE_CANCEL`（SPEC §10 處罰分級，**同時寫入 `app_user.next_request_allowed_at = now() + 30 分鐘`，v1.7 冷卻機制，SPEC §6.3；`EARLY_CANCEL` 不觸發**）。 |

錯誤碼：`NOT_ACTIVITY_MEMBER`、`CONTACT_EXPIRED`、`ACTIVITY_ALREADY_ENDED`

---

## 7. 完成確認 / 再約

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 7.1 | `rpc: submit_completion_report(activity_id, result, absent_user_ids?)` | A3 | 三選一（SPEC §10）。`absent_user_ids` 僅 `result=REPORTED_ABSENT` 時必填，且限定該活動成員。每人一次（DB unique）。達 ≥50% 門檻時由本 RPC 內嵌觸發結算：多數決記 `NO_SHOW`／`ATTENDED`；2 人互咬不判；連續 3 次 No-show → 寫 `suspended_until`。 |
| 7.2 | `rpc: rematch_vote(activity_id, to_user_id)` | — | 按「👍 再約」。當對方也投過（雙向成立）→ 該兩人間聯絡方式永久保留（6.2 的判定來源），並各發通知。 |

錯誤碼：`ALREADY_REPORTED`、`INVALID_ABSENT_TARGET`（指認對象不在成員名單）、`ACTIVITY_NOT_ENDED`

---

## 8. Notification

| # | Endpoint | 說明 |
|---|---|---|
| 8.1 | `GET notification`（PostgREST，RLS：own） | 收件匣，`payload` 帶 deep-link 所需 id。 |
| 8.2 | `PATCH notification`（RLS：own） | 標記已讀（`read_at`）。 |
| 8.3 | Push | FCM（SPEC §13），由背景任務發送，非 client API。 |

---

## 9. 背景任務（非公開 API，pg_cron / Edge Function 排程）

| 任務 | 頻率 | 對應轉移 | 說明 |
|---|---|---|---|
| Matching Engine | 每分鐘 | R3a / R3b | 掃描 Queue 中時間窗重疊 + 地點相同的 Request 組合，達到 `min_participants` 貪婪成局：<br>① **若本次實際撮合人數 > 2**：直接建立 `Activity` (R3a)。<br>② **若本次實際撮合人數 ≤ 2**：建立 `pending_confirmation` 記錄，並將對應的 `match_request.status` 標記為 `PENDING_CONFIRMATION` (R3b)。 |
| PENDING_CONFIRMATION 超時與拒絕清理 | 每分鐘 | PC2 | 掃描 `confirm_window_expire_at < now()` 且為 `PENDING`、或已標記 `DECLINED` 的記錄：<br>① 將 `pending_confirmation.status` 設定為 `TIMEOUT` / `DECLINED`。<br>② 寫入 `match_history_avoidance` 降權記錄（正規化 `user_a_id < user_b_id`，避開 7 天）。<br>③ **雙方 Request 無差別退回 Queue (`REQUESTING`)** 重新進池（若 `latest_start` 已過期則自然轉為 `EXPIRED`）。<br>④ 向雙方發送無差別「配對未成立」通知（不暴露對方回應與超時原因）。 |
| Request 過期 | 每分鐘 | R4、Downgrade | `latest_start` 已過且未成團 → `EXPIRED`；期限前未滿員且 `allow_downgrade` 且餘 ≥10 分鐘 → 建立 `downgrade_request`。 |
| Downgrade 超時 | 每分鐘 | — | `expire_at` 已過 → `TIMEOUT`，Request 以原門檻留在 Queue 中。 |
| Activity 開始 | 每分鐘 | A2 | `start_time` 已到 → `ONGOING`；發送 `ACTIVITY_REMINDER` 通知。 |
| Activity 超時完成 | 每小時 | A4 | `start_time + 24h` 未達回報門檻 → `COMPLETED`，不做 No-show 判定。 |
| 結束提醒 | 每 15 分鐘 | — | `estimated_end_time` 已過 → 發送 `COMPLETE_CONFIRMATION` 通知。 |

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
