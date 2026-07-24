# API Endpoint Spec — 校園活動配對 App（派生自 SPEC v1.3）

> 本文件由 [SPEC.md](SPEC.md) 推導，建立在 [ERD.md](ERD.md) 定案之上。若與 SPEC 衝突，先改 SPEC。

## 0. 總約定

- **後端形態**：Supabase。純讀取走 PostgREST（RLS 已在 migration 定義）；**所有狀態轉移一律走 RPC**（`security definer` Postgres function，經 `supabase.rpc()` 呼叫），client 不直接 update 狀態欄位。轉移的合法性以 [STATE_MACHINE.md](STATE_MACHINE.md) 為準（編號 R1–R5、A1–A6）。
- **驗證**：所有呼叫需 Supabase Auth JWT（信箱 OTP 登入）。`auth.uid()` 即操作者，request body 不帶 user_id。
- **錯誤格式**：RPC 以 `raise exception using errcode, message` 回傳；下表的「錯誤碼」為 message 內的機器可讀代碼。
- **停權檢查**：`suspended_until > now()` 的使用者呼叫任何寫入類 RPC 一律回 `USER_SUSPENDED`。

---

## 1. Auth / Profile

| # | Endpoint | 說明 |
|---|---|---|
| 1.1 | `auth.signInWithOtp({ email })` | Supabase 內建。前端先擋非 `@nycu.edu.tw` / `@nthu.edu.tw`；DB 端 `app_user.email` CHECK 為最終防線（SPEC §2：完整雙校網域比對，非 `.edu.tw` 後綴） |
| 1.2 | `rpc: complete_profile(display_name, avatar_url, gender?, bio?, contact_ig?, contact_line?, contact_discord?)` | 註冊硬性門檻（SPEC §2）：`avatar_url` 必填 + 三項聯絡方式至少一項。`bio` 選填、不卡門檻（SPEC v1.3）。未完成必填項前所有 Request 類 RPC 回 `PROFILE_INCOMPLETE`。**`school` 不是參數**——由 email 網域 mapping（`nycu.edu.tw → NYCU`、`nthu.edu.tw → NTHU`）在 server 端寫入，DB CHECK 保證與網域一致（SPEC §2：不讓使用者自選） |
| 1.3 | `PATCH app_user`（PostgREST，RLS：own row） | 更新個人資料（含 `bio`）；DB CHECK 保證改完仍滿足硬性門檻 |
| 1.4 | `rpc: get_my_reliability()` | 回 `{ tier: TRUSTED\|NORMAL\|NEW, is_new_user: bool }`，即時由 `fn_reliability_tier` / `fn_is_new_user` 計算（SPEC §12：不存分數欄位） |

錯誤碼：`INVALID_EMAIL_DOMAIN`、`PROFILE_INCOMPLETE`、`NO_CONTACT_METHOD`

## 2. ActivityType / Location

| # | Endpoint | 說明 |
|---|---|---|
| 2.1 | `GET activity_type?status=eq.APPROVED`（PostgREST） | 公開類型清單 |
| 2.2 | `rpc: search_activity_type(query)` | 新增前的模糊比對/autocomplete（SPEC §5，防「羽球 vs 羽毛球」重複稀釋配對池） |
| 2.3 | `rpc: propose_activity_type(name)` | 流程：關鍵字黑名單預檢（命中即回 `NAME_BLACKLISTED`，不落庫）→ `PENDING` → admin 審核。審核走 Supabase Dashboard/service role，MVP 不做 admin API |
| 2.4 | `GET location?is_active=eq.true&school=eq.{我的 school}`（PostgREST) | 固定地點下拉清單，依校分列（SPEC §1）；client 只顯示自己學校的清單，server 端最終由 3.1 的 `SCHOOL_LOCATION_MISMATCH` 把關 |

錯誤碼：`NAME_BLACKLISTED`、`DUPLICATE_TYPE_NAME`

## 3. MatchRequest（找人流程；只動 `match_request` 側）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 3.1 | `rpc: create_request(activity_type_id, campus_location_id, bucket, required_total, allow_downgrade, invited_user_ids?)` | R1 | `bucket ∈ {NOW, TODAY, TONIGHT, TOMORROW_AM}`，server 端換算成 `earliest_start/latest_start`（SPEC §4：桶是 UI 包裝，引擎只看具體時間）。檢查 `campus_location_id` 屬於 owner 的 `school`，否則回 `SCHOOL_LOCATION_MISMATCH`（SPEC §6/§7 同校池隔離）。`invited_user_ids` = 已組好的朋友，直接寫進 `request_member`（SPEC §6：不做 FriendGroup 表） |
| 3.2 | `rpc: submit_request(request_id)` | R2 | 送出進 Queue。依序檢查：profile 門檻 → 單一 REQUESTING 限制 → 24h 窗 → **新人低人數限制**（`required_total ≤ 2` 且任一成員 `fn_is_new_user()` = true → 拒絕，SPEC §12.1） |
| 3.3 | `rpc: cancel_request(request_id)` | R5 | 配對成立前取消，不記 Reliability 事件 |
| 3.4 | `rpc: join_request(request_id)` | — | 加入他人 Request 成為 member；同樣過 3.2 的新人低人數檢查（SPEC §7「不能發起也不能加入」） |
| 3.5 | `rpc: leave_request(request_id)` | — | member 退出（`request_member.status → LEFT`）；配對成立前退出不記事件 |
| 3.6 | `GET match_request`（PostgREST，RLS：owner 或成員） | — | 查自己的 Request 與狀態 |

錯誤碼：`ALREADY_REQUESTING`（單一 REQUESTING 限制）、`WINDOW_EXCEEDS_24H`、`NEW_USER_LOW_HEADCOUNT`（新人不可 ≤2 人局）、`SCHOOL_LOCATION_MISMATCH`（地點不屬於自己學校）、`REQUEST_NOT_OPEN`、`USER_SUSPENDED`

## 4. Downgrade（掛在 REQUESTING 內部）

| # | Endpoint | 說明 |
|---|---|---|
| 4.1 | `rpc: respond_downgrade(downgrade_request_id, agree: bool)` | 10 分鐘 `CONSENT_WINDOW` 內回應；過期回 `CONSENT_WINDOW_CLOSED`（超時=拒絕，Request 以原門檻回池，SPEC §8）。發起端是系統（Matching Engine），沒有使用者發起的 endpoint |
| 4.2 | `GET downgrade_request`（PostgREST，RLS：被詢問成員） | 查進行中的降門檻詢問 |

錯誤碼：`CONSENT_WINDOW_CLOSED`、`ALREADY_RESPONDED`

## 5. Activity（實際活動；只動 `activity` 側）

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 5.1 | `GET activity` + `GET activity_member`（PostgREST，RLS：成員） | — | 我的活動、成員名單、`source_request_id` 來源 |
| 5.2 | `rpc: get_activity_contacts(activity_id)` | — | **聯絡方式唯一出口**（不走 RLS 直讀 `app_user.contact_*`）。規則（SPEC §11）：呼叫者是該活動成員，且（`now() < contact_visible_until`【以 Activity 的 created_at 起算，SPEC v1.1 變更 5】**或** 與對方互按過再約）。回各成員自選公開的聯絡方式 |
| 5.3 | `rpc: cancel_activity_participation(activity_id)` | A5/A6 | 個別取消。server 依時點記事件：開始前 ≥1h → `EARLY_CANCEL`（不計入記錄）；<1h 或已開始 → `LATE_CANCEL`（SPEC §10 處罰分級） |

錯誤碼：`NOT_ACTIVITY_MEMBER`、`CONTACT_EXPIRED`、`ACTIVITY_ALREADY_ENDED`

## 6. 完成確認 / 再約

| # | Endpoint | State Machine | 說明 |
|---|---|---|---|
| 6.1 | `rpc: submit_completion_report(activity_id, result, absent_user_ids?)` | A3 | 三選一（SPEC §10）。`absent_user_ids` 僅 `result=REPORTED_ABSENT` 時必填，且限定該活動成員。每人一次（DB unique）。達 ≥50% 門檻時由本 RPC 內嵌觸發結算：多數決記 `NO_SHOW`／`ATTENDED`；2 人互咬不判；連續 3 次 No-show → 寫 `suspended_until` |
| 6.2 | `rpc: rematch_vote(activity_id, to_user_id)` | — | 按「👍 再約」。當對方也投過（雙向成立）→ 該兩人間聯絡方式永久保留（5.2 的判定來源），並各發通知 |

錯誤碼：`ALREADY_REPORTED`、`INVALID_ABSENT_TARGET`（指認對象不在成員名單）、`ACTIVITY_NOT_ENDED`

## 7. Notification

| # | Endpoint | 說明 |
|---|---|---|
| 7.1 | `GET notification`（PostgREST，RLS：own） | 收件匣，`payload` 帶 deep-link 所需 id |
| 7.2 | `PATCH notification`（RLS：own） | 標記已讀（`read_at`） |
| 7.3 | Push | FCM（SPEC §13），由背景任務發送，非 client API |

## 8. 背景任務（非公開 API，pg_cron / Edge Function 排程）

| 任務 | 頻率 | 對應轉移 |
|---|---|---|
| Matching Engine：掃描各 `activity_type` Queue，時間窗重疊 + 地點相同 → merge 建 Activity | 每分鐘 | R3 / A1 |
| Request 過期：`latest_start` 已過且未成團 → `EXPIRED`；期限前未滿員且 `allow_downgrade` 且餘 ≥10 分鐘 → 建 `downgrade_request` | 每分鐘 | R4、Downgrade 子流程 |
| Downgrade 超時：`expire_at` 已過 → `TIMEOUT`，Request 回池 | 每分鐘 | — |
| Activity 開始：`start_time` 已到 → `ONGOING`；並發 `ACTIVITY_REMINDER` | 每分鐘 | A2 |
| Activity 超時完成：`start_time + 24h` 未達回報門檻 → `COMPLETED`，不判 No-show | 每小時 | A4 |
| 結束提醒：`estimated_end_time` 已過 → 發 `COMPLETE_CONFIRMATION` 通知 | 每 15 分鐘 | — |

---

## 9. 覆蓋檢查（SPEC 規則 ↔ 落點）

| SPEC 規則 | 落點 |
|---|---|
| §2 網域驗證（雙校） | 1.1 + DB CHECK |
| §2 school 自動判定、不讓 user 選 | 1.2 server 端 mapping + DB CHECK |
| §2 profile 硬門檻 | 1.2 + 3.2/3.4 前置檢查 + DB CHECK |
| §2 `bio` 選填、不進配對邏輯 | 1.2/1.3（無門檻檢查）+ ERD `app_user.bio` 無 NOT NULL |
| §6/§7 配對池同校隔離 | 3.1 的 `SCHOOL_LOCATION_MISMATCH` + location 的 school 歸屬 |
| §6 單一 REQUESTING | 3.2 + partial unique index |
| §7/§12.1 新人低人數限制 | 3.2 / 3.4 的 `NEW_USER_LOW_HEADCOUNT` |
| §8 Downgrade 全套 | 4.1 + 背景任務 |
| §9 兩張狀態圖分離 | §3 只動 request、§5 只動 activity 的 endpoint 邊界 |
| §10 多數決 / 2 人互咬 / 停權 | 6.1 結算邏輯 |
| §11 聯絡方式 24h + 再約永久保留 | 5.2 + 6.2 |
| §12 Reliability 即時 query | 1.4 |
