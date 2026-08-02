import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 單一判斷點：是否該用 Cupertino 風格的系統元件（導覽列、對話框、選擇器、
/// 分段控制、載入指示器）。Web 平台的 `dart:io` 沒有真正的 OS 可問，
/// `Platform.isIOS` 在 web 上會丟 [UnsupportedError]，所以一律先擋
/// `kIsWeb`——瀏覽器預覽固定走 Material 分支，跟這支 App 目前唯二的正式
/// 平台目標（iOS／Android）分開判斷。
bool get isCupertino => !kIsWeb && Platform.isIOS;
