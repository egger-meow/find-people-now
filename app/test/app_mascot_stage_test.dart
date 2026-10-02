import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/auth/otp_login_screen.dart';
import 'package:find_people_now/widgets/app_error_state.dart';
import 'package:find_people_now/widgets/app_mascot_stage.dart';

void main() {
  group('AppMascotStage Widget Tests', () {
    testWidgets('renders hero style with image and semantic label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMascotStage(
              assetPath: 'assets/mascot/login.png',
              height: 156,
              style: AppMascotStageStyle.hero,
              semanticLabel: '街街貓迎賓',
            ),
          ),
        ),
      );

      expect(find.byType(AppMascotStage), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.bySemanticsLabel('街街貓迎賓'), findsOneWidget);

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, 'assets/mascot/login.png');
      expect(image.height, 156);
    });

    testWidgets('renders card style without ground shadow when disabled', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMascotStage(
              assetPath: 'assets/mascot/explore_empty.png',
              height: 100,
              style: AppMascotStageStyle.card,
              showGroundShadow: false,
              semanticLabel: '空狀態街街貓',
            ),
          ),
        ),
      );

      expect(find.byType(AppMascotStage), findsOneWidget);
      expect(find.bySemanticsLabel('空狀態街街貓'), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, 'assets/mascot/explore_empty.png');
    });

    testWidgets('renders celebration style with custom badge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMascotStage(
              assetPath: 'assets/mascot/matched.png',
              height: 120,
              style: AppMascotStageStyle.celebration,
              badge: Chip(label: Text('成團！')),
            ),
          ),
        ),
      );

      expect(find.text('成團！'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('renders alert style properly for error states', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMascotStage(
              assetPath: 'assets/mascot/error_06.png',
              height: 90,
              style: AppMascotStageStyle.alert,
              semanticLabel: '出錯街街貓',
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('出錯街街貓'), findsOneWidget);
    });

    testWidgets('OtpLoginScreen renders AppMascotStage hero and campus verified badge', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: OtpLoginScreen(),
          ),
        ),
      );

      expect(find.byType(AppMascotStage), findsOneWidget);
      expect(find.text('敢不敢揪'), findsOneWidget);
      expect(find.text('找到現在也想一起的人。'), findsOneWidget);
      expect(find.text('陽明交大 / 清華 校園即刻揪團'), findsOneWidget);
      expect(find.text('學校信箱'), findsOneWidget);
      expect(find.text('傳送驗證碼'), findsOneWidget);
    });

    testWidgets('AppErrorState embeds AppMascotStage with alert styling', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppErrorState(
              message: '連線逾時，請檢查網路',
            ),
          ),
        ),
      );

      expect(find.byType(AppMascotStage), findsOneWidget);
      expect(find.text('出了點問題'), findsOneWidget);
      expect(find.text('連線逾時，請檢查網路'), findsOneWidget);
      expect(find.bySemanticsLabel('眼冒金星的街街貓'), findsOneWidget);
    });

    testWidgets('AppMascotStage provides fallback icon on error', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMascotStage(
              assetPath: 'assets/mascot/matching.png',
              height: 120,
              style: AppMascotStageStyle.waiting,
            ),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.errorBuilder, isNotNull);

      final context = tester.element(find.byType(Image));
      final fallbackWidget = image.errorBuilder!(context, Exception('Asset not found'), null);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: fallbackWidget)));

      expect(find.byIcon(Icons.radar_rounded), findsOneWidget);
    });
  });
}
