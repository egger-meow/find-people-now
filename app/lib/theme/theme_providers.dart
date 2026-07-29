import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 反饋：「我的資訊頁 要加 白/暗 模式(預設一樣跟系統)」——先前 [MyApp] 寫死
/// `themeMode: ThemeMode.system`，沒有讓使用者覆寫的入口。這裡用
/// [SharedPreferences] 存使用者的手動選擇，預設值仍是 [ThemeMode.system]
/// （沒存過就跟系統走，符合反饋原句）。
const _prefsKey = 'theme_mode';

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    final mode = ThemeMode.values.firstWhere(
      (m) => m.name == stored,
      orElse: () => ThemeMode.system,
    );
    state = mode;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
