# find-people-now

校園活動配對 App — 讓學生臨時想做一件事（打球、喝咖啡、散步、讀書、etc）時，能在 24 小時內找到人一起去，而不用發 LINE 群組碰運氣。

**目前是 MVP 階段**：服務範圍先限定 NYCU + NTHU（清交同一生活圈，跨校活動本就常見，適合驗證冷啟動），**不是產品的最終定位**。跨校配對、多校擴張是刻意保留的 future feature，只是 MVP 先不打開，細節見 [docs/SPEC.md](docs/SPEC.md) 的 v1.2 變更紀錄與第 7 節。

目前處於規格與資料模型設計階段，尚未開始寫程式。

## 出發點

大二大三之後，每個人都有自己的生活步調和規劃——不是沒朋友，是大家都很忙。要揪人，通常得提前好幾個禮拜約，才約得到大家都空的時間。

問題是：想做一件事的念頭，往往不是提前好幾週出現的。可能是突然想跑步、想找人一起健身、想打球，甚至只是想找人聊聊天——但那個當下，朋友大多已經有自己的安排了。所以即使朋友很多，「臨時、當下就能約出人」這件事，在大學和研究所的生活型態裡其實是稀缺的。這就是這個 App 想解決的問題。

阿還可以順便交朋友，我他媽都沒朋友

## 文件

所有文件在 [`docs/`](docs)，`docs/SPEC.md` 是唯一真相來源（single source of truth）；其餘文件皆由它推導，若有衝突以 SPEC.md 為準。

| 文件 | 內容 |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | 產品規格書：範圍、核心流程、規則與取捨理由 |
| [docs/ERD.md](docs/ERD.md) | 資料模型 ERD、enum 定案總表 |
| [docs/STATE_MACHINE.md](docs/STATE_MACHINE.md) | MatchRequest / Activity 狀態機與轉移條件 |
| [docs/API.md](docs/API.md) | API endpoint spec |
| [docs/migrations/](docs/migrations) | Supabase SQL migration |

## 技術棧

- 行動端：Flutter
- 後端：Supabase（Auth / PostgreSQL / Realtime / Storage）
- 通知：Firebase Cloud Messaging
- 地圖：Google Maps API

## 現況

- [x] Spec 定案（v1.2）
- [x] ERD
- [x] State Machine
- [x] Supabase migration（初版）
- [x] API endpoint spec
- [ ] Wireframe / User Flow
- [ ] 實作
