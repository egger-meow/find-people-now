import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'errors/user_error_message.dart';
import 'notifications/web_push_service.dart';
import 'router/app_router.dart';
import 'supabase_bootstrap.dart';
import 'theme/app_theme.dart';
import 'theme/theme_providers.dart';
import 'widgets/app_error_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installUserSafeErrorBoundary();

  try {
    await initSupabase();
    runApp(const ProviderScope(child: MyApp()));
  } catch (error, stackTrace) {
    _reportUnexpectedError(error, stackTrace);
    runApp(const _StartupErrorApp());
  }
}

void _installUserSafeErrorBoundary() {
  ErrorWidget.builder = buildUserSafeErrorWidget;

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    _reportUnexpectedError(error, stackTrace);
    return true;
  };
}

void _reportUnexpectedError(Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'find_people_now',
    ),
  );
}

/// Public for regression coverage without mutating Flutter's global builder.
Widget buildUserSafeErrorWidget(FlutterErrorDetails details) {
  if (kDebugMode) FlutterError.presentError(details);
  return const AppErrorState();
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '敢不敢揪',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const Scaffold(
        body: SafeArea(
          child: AppErrorState(message: userSafeUnexpectedErrorMessage),
        ),
      ),
    );
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pushSyncCoordinatorProvider);
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
        // 上限經 P1/P2 針對主要表單、清單與按鈕實裝動態折行與滾動保護後，
        // 由原先 1.3 漸進擴展至 1.6，兼顧大字型無障礙需求與版面穩定度。
        // 下限 0.9 則是擋掉「縮到太小反而看不清楚」。
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.6,
            ),
          ),
          child: child!,
        );
      },
    );
  }
}
