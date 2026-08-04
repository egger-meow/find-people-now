import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router/app_router.dart';
import 'supabase_bootstrap.dart';
import 'theme/app_theme.dart';
import 'theme/theme_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSupabase();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: '敢不敢揪',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Dynamic Type（iOS 設定 > 螢幕顯示與亮度 > 文字大小，以及輔助使用裡
        // 更大的「更大的文字」）最大可以放到約 3.1 倍。這支 App 有大量固定
        // 高度的元素——44pt 的活動類型 icon 色塊、52pt 的膠囊按鈕、底部
        // Tab Bar、狀態晶片——3 倍字級會直接撐爆版面（文字溢出、按鈕互相
        // 重疊、卡片內容被截掉）。
        //
        // 完全不支援縮放（`textScaler: TextScaler.noScaling`）是錯的：那等於
        // 對視力需求的使用者說「不關我的事」，HIG/WCAG 都明確反對。這裡取
        // 中間做法——**尊重使用者的放大意圖，但夾在版面撐得住的範圍內**。
        // 上限 1.3 是實測值：再往上，底部 Tab Bar 的四個中文標籤就會開始
        // 互相擠壓。下限 0.9 則是擋掉「縮到太小反而看不清楚」。
        //
        // 這是一個已知的取捨，不是最終答案：真正的解是把固定高度改成
        // intrinsic 高度，讓版面自己長高。那是比這次 UI 強化更大的改動範圍，
        // 先用夾擠確保不會壞掉。
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.3),
          ),
          child: child!,
        );
      },
    );
  }
}
