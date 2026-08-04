// 平台分岔（iOS Cupertino ↔ Android Material）的回歸測試。
//
// 這層先前完全沒有測試覆蓋：`isCupertino` 舊實作是 `!kIsWeb && Platform.isIOS`，
// 在 `flutter test`（桌機 Dart VM）底下永遠是 false，所以**每一條 iOS 分支都
// 從來沒有被執行過**——連「會不會直接丟例外」都不知道，只能靠實機點看看。
//
// 改用 [defaultTargetPlatform] 之後（見 lib/theme/platform_adaptive.dart），
// 這些分支可以用 `debugDefaultTargetPlatformOverride` 在測試裡逐一驗證。
// 這裡驗的是「有沒有選到正確的平台元件」，不是像素外觀——外觀本來就該由
// Flutter 自己的 widget 測試保證，這裡要防的是有人加新畫面時忘了分岔、
// 或把某個分支改壞而沒人發現。
//
// 這支測試不碰 Supabase，純粹是 widget 樹的組裝驗證，因此不需要本機後端。
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/theme/platform_adaptive.dart';
import 'package:find_people_now/widgets/adaptive_refresh.dart';
import 'package:find_people_now/widgets/app_card.dart';
import 'package:find_people_now/widgets/app_dialog.dart';
import 'package:find_people_now/widgets/countdown_text.dart';
import 'package:find_people_now/widgets/loading_indicator.dart';

/// 把 widget 包進最小可用的 [MaterialApp] 外殼（Material 元件需要
/// `Directionality`／`MediaQuery`／`Theme` 祖先才能 build）。
Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

/// `debugDefaultTargetPlatformOverride` 必須在**測試主體結束前**還原：
/// `flutter_test` 會在每個 test body 跑完、tearDown 之前檢查所有 foundation
/// debug 變數都是未設定狀態，放在 `tearDown` 裡還原已經太晚（會被判定為
/// 「測試改動了 debug 變數」而整批失敗）。用 try/finally 包住確保即使斷言
/// 失敗也會還原，不會污染同檔案後面的測試。
Future<void> _withPlatform(TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('isCupertino', () {
    test('iOS 為 true，Android 為 false', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(isCupertino, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(isCupertino, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('LoadingIndicator', () {
    testWidgets('iOS 用 CupertinoActivityIndicator', (tester) async {
      await _withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(const LoadingIndicator()));
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });

    testWidgets('Android 用 CircularProgressIndicator', (tester) async {
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(const LoadingIndicator()));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(CupertinoActivityIndicator), findsNothing);
      });
    });
  });

  group('AppAdaptiveDialog', () {
    Widget dialog() => const AppAdaptiveDialog(
          title: '標題',
          actions: [AppDialogAction(label: '確定', onPressed: null)],
        );

    testWidgets('iOS 用 CupertinoAlertDialog', (tester) async {
      await _withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(dialog()));
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      });
    });

    testWidgets('Android 用 Material AlertDialog', (tester) async {
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(dialog()));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
      });
    });
  });

  group('AdaptiveRefresh', () {
    Widget refresh() => AdaptiveRefresh(
          onRefresh: () async {},
          slivers: const [SliverToBoxAdapter(child: SizedBox(height: 40))],
        );

    testWidgets('iOS 用 CupertinoSliverRefreshControl，不掛 Material 的 RefreshIndicator', (tester) async {
      await _withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(refresh()));
        // 閒置時這個 sliver 位於負的捲動位移（畫面上緣之外），`find.byType` 預設的
        // `skipOffstage: true` 會把它濾掉——它確實在樹上，只是不在畫面內。
        expect(find.byType(CupertinoSliverRefreshControl, skipOffstage: false), findsOneWidget);
        expect(find.byType(RefreshIndicator), findsNothing);
      });
    });

    testWidgets('Android 用 RefreshIndicator，不掛 Cupertino 的下拉控制項', (tester) async {
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(refresh()));
        expect(find.byType(RefreshIndicator), findsOneWidget);
        expect(find.byType(CupertinoSliverRefreshControl, skipOffstage: false), findsNothing);
      });
    });

    testWidgets('內容不滿一頁時仍可捲動（下拉更新在空清單上也要能觸發）', (tester) async {
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(refresh()));
        final scrollView = tester.widget<CustomScrollView>(find.byType(CustomScrollView));
        expect(scrollView.physics, isA<AlwaysScrollableScrollPhysics>());
      });
    });
  });

  group('AppCard 按壓回饋', () {
    testWidgets('iOS 不用 Material 墨水漣漪', (tester) async {
      await _withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(AppCard(onTap: () {}, child: const Text('x'))));
        expect(find.byType(InkWell), findsNothing);
      });
    });

    testWidgets('Android 用 InkWell 漣漪', (tester) async {
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(AppCard(onTap: () {}, child: const Text('x'))));
        expect(find.byType(InkWell), findsOneWidget);
      });
    });

    testWidgets('沒有 onTap 時不產生可點區域', (tester) async {
      await _withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(const AppCard(child: Text('x'))));
        expect(find.byType(InkWell), findsNothing);
      });
    });

    testWidgets('semanticLabel 會把整張卡片併成單一語意節點', (tester) async {
      final handle = tester.ensureSemantics();
      await _withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_host(
          AppCard(onTap: () {}, semanticLabel: '籃球，今天 14:00', child: const Text('籃球')),
        ));
        expect(find.bySemanticsLabel('籃球，今天 14:00'), findsOneWidget);
        // 合併之後，底層那段文字不再各自曝光給螢幕閱讀器。
        expect(find.bySemanticsLabel('籃球'), findsNothing);
      });
      handle.dispose();
    });
  });

  group('CountdownText', () {
    testWidgets('倒數數字使用等寬字元，避免每秒重繪時寬度抽動', (tester) async {
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      await tester.pumpWidget(_host(CountdownText(deadline: deadline)));

      final text = tester.widget<Text>(find.byType(Text));
      expect(text.style?.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('逾時文案是中文、不套等寬處理', (tester) async {
      final past = DateTime.now().subtract(const Duration(minutes: 1));
      await tester.pumpWidget(_host(CountdownText(deadline: past, expiredLabel: '已逾時')));

      expect(find.text('已逾時'), findsOneWidget);
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.style?.fontFeatures, isNull);
    });
  });

  group('AppMotion 減少動態效果', () {
    testWidgets('disableAnimations 開啟時時長歸零、裝飾性動畫關閉', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(builder: (context) {
            captured = context;
            return const SizedBox();
          }),
        ),
      ));

      expect(AppMotion.duration(captured, AppMotion.normal), Duration.zero);
      expect(AppMotion.allowsDecorative(captured), isFalse);
    });

    testWidgets('預設情況下維持原本時長', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          captured = context;
          return const SizedBox();
        }),
      ));

      expect(AppMotion.duration(captured, AppMotion.normal), AppMotion.normal);
      expect(AppMotion.allowsDecorative(captured), isTrue);
    });
  });
}
