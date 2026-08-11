# 使用者安全錯誤邊界設計

## 目標

任何使用者可見介面都不得直接顯示 exception、stack trace、Supabase/PostgREST 訊息、RPC 錯誤碼或其他只適合開發者閱讀的內容。可預期且能協助使用者修正操作的情況，仍顯示清楚的繁體中文提示；無法辨識的錯誤統一顯示「Oops！系統出了點狀況，請稍後再試」。

本次只改前端錯誤呈現與防護，不更動 backend、schema、RPC、route 或既有狀態機。

## 架構

新增單一的使用者錯誤訊息轉譯層。畫面不得自行插入 `$error`、`exception.toString()`、`ApiException.code.name` 或 `detail`，而是把錯誤與操作情境交給轉譯層。

轉譯層依序處理：

1. 已知且可行動的業務錯誤：輸出既有或改善後的友善繁中，例如邀請碼無效、操作冷卻中、已回報過。
2. 已知的網路或暫時性錯誤：輸出不含技術資訊的重試提示。
3. 未知錯誤：固定輸出「Oops！系統出了點狀況，請稍後再試」。

原始 error 與 stack trace 只進開發紀錄，不成為任何 Widget 的文字。

## 使用者介面

- `AsyncValue.error`、頁面錯誤區塊、SnackBar、dialog 與表單送出錯誤統一使用轉譯層。
- 錯誤訊息維持 Calm Glass 視覺語言，不呈現 Flutter 紅色錯誤畫面。
- 可恢復的載入錯誤提供「再試一次」；無法原地恢復時提供安全的返回入口。
- 不把所有錯誤都模糊化：使用者操作可修正的狀況必須保留具體說明。

## 全域最後防線

App 根層設定 release-safe 的 framework error fallback。若仍有未捕捉的 build error，使用者只看到一致的友善錯誤畫面，不會看到 exception、widget diagnostics 或 stack trace。

這個 fallback 是最後防線，不取代各功能正常的錯誤處理。Debug 記錄仍保留足夠資訊供開發者定位。

## 安全規則

- 禁止把任意 server-provided `message`、`details`、`hint`、錯誤碼或 exception 字串直接呈現。
- 業務錯誤必須以本地白名單映射；未列入白名單的一律使用通用訊息。
- 使用者輸入驗證訊息不屬於技術錯誤，可照常顯示，例如「請輸入邀請碼」。
- 成功、取消與空狀態的既有文案及功能保持不變。

## 驗證

- 靜態掃描 production Dart，確認沒有 exception、`code.name`、`detail` 或 `$error` 直接流入使用者文字。
- Widget tests 驗證已知業務錯誤仍為友善繁中。
- Widget tests 驗證未知 exception、Supabase/PostgREST 原文與 stack trace 不出現在畫面。
- 驗證全域 fallback 不顯示 Flutter 技術錯誤內容，並保有可恢復入口。
- 執行 focused tests、`flutter analyze`，再執行適當的 final regression。

## 完成條件

使用者在所有已盤點的主要流程中，只可能看到本地定義的繁中錯誤訊息；任何未預期錯誤也會被全域最後防線擋住。開發者仍能從 debug log 取得原始錯誤資訊。
