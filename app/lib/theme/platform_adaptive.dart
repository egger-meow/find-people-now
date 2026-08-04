import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

/// 單一判斷點：是否該用 Cupertino 風格的系統元件（導覽列、對話框、選擇器、
/// 分段控制、載入指示器、下拉更新、卡片按壓回饋）。
///
/// 從 `!kIsWeb && Platform.isIOS` 改成 [defaultTargetPlatform]：
///
/// 原本的寫法是為了繞開「`dart:io` 的 `Platform.isIOS` 在 web 上會丟
/// [UnsupportedError]」這個限制，用 `kIsWeb` 擋在前面。避免當掉是對的，但
/// 副作用是**所有** web 情境都被釘死在 Material 分支——包含用 iPhone Safari
/// 開這個 web build 的真實使用者，他們會拿到 Android 的視覺語言。
///
/// [defaultTargetPlatform] 是 Flutter 官方在框架內部做平台分岔用的判斷（
/// `Theme`、`Scrollable`、`TextSelection` 全都靠它），它在所有平台上都安全、
/// 不需要 `dart:io`，在 web 上則由 engine 依 user agent 判定。
///
/// 對這支 App 正式支援的兩個平台（iOS／Android 原生）而言，**行為與改動前
/// 完全相同**：原生 iOS 上兩種寫法都是 true，原生 Android 上都是 false。
/// 真正改變的只有 web：iOS 裝置的瀏覽器現在會拿到 iOS 外觀，桌機瀏覽器
/// （macOS/Windows/Linux）仍然走 Material 分支，跟先前一致。
///
/// 附帶好處：因為判斷來源變成一個可覆寫的全域值，開發時可以用
/// `debugDefaultTargetPlatformOverride = TargetPlatform.iOS` 在桌機瀏覽器
/// 預覽 iOS 分支——先前這條路完全不存在，iOS 專屬的介面只能靠實機驗證。
bool get isCupertino => defaultTargetPlatform == TargetPlatform.iOS;
