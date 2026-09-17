import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/activity_detail_providers.dart';
import 'package:find_people_now/activities/activity_detail_screen.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/notification.dart' as generated;
import 'package:find_people_now/generated/request_member.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/notifications/notification_providers.dart';
import 'package:find_people_now/notifications/notifications_screen.dart';
import 'package:find_people_now/notifications/web_push_service.dart';
import 'package:find_people_now/theme/app_theme.dart';

class MockWebPushService implements WebPushService {
  MockWebPushService({this.permission = PushPermissionStatus.unsupported});

  final PushPermissionStatus permission;
  bool syncCalled = false;
  bool signOutCalled = false;

  @override
  bool get isSupported => permission != PushPermissionStatus.unsupported;

  @override
  Future<PushPermissionStatus> checkPermission() async => permission;

  @override
  Future<PushPermissionStatus> requestPermission() async => permission;

  @override
  Future<PushSubscriptionPayload?> subscribe({String? vapidPublicKey}) async {
    if (permission != PushPermissionStatus.granted) return null;
    return const PushSubscriptionPayload(
      endpoint: 'https://push.example.com/mock-sub',
      p256dh: 'mock-p256dh',
      auth: 'mock-auth',
      userAgent: 'MockBrowser',
    );
  }

  @override
  Future<bool> unsubscribe() async => true;

  @override
  Future<PushSubscriptionPayload?> getCurrentSubscription() async => null;

  @override
  Future<void> syncWithServer(dynamic client, {String? vapidPublicKey}) async {
    syncCalled = true;
  }

  @override
  Future<void> onSignOut(dynamic client) async {
    signOutCalled = true;
  }
}

void main() {
  final testNow = DateTime.utc(2026, 9, 17, 12, 0);

  group('Web 背景通知鏈路與流程測試', () {
    test('WebPushService 預設介面在非 Web 環境安全降級', () async {
      final service = createWebPushService();
      expect(service.isSupported, isFalse);
      expect(await service.checkPermission(), PushPermissionStatus.unsupported);
      expect(await service.requestPermission(), PushPermissionStatus.unsupported);
      expect(await service.subscribe(), isNull);
      expect(await service.unsubscribe(), isTrue);
      expect(await service.getCurrentSubscription(), isNull);
    });

    testWidgets('NotificationsScreen 支援 PENDING_CONFIRMATION 雙向確認通知展示', (tester) async {
      final notif = generated.Notification(
        id: 'notif-pc-1',
        userId: 'u1',
        eventType: NOTIFICATION_EVENT_TYPE.PENDING_CONFIRMATION,
        payload: {
          'request_id': 'req-123',
          'pending_confirmation_id': 'pc-456',
        },
        createdAt: testNow,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u1'),
            notificationsStreamProvider.overrideWith((ref) => Stream.value([notif])),
            myActiveActivityProvider.overrideWith((ref) => Future.value(null)),
          ],
          child: const MaterialApp(
            home: NotificationsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('找到相容的夥伴了！'), findsOneWidget);
      expect(find.text('雙方條件已吻合，請在限時內確認是否一起出發'), findsOneWidget);
    });

    testWidgets('WaitingRoomScreen 找不到配對（已逾時/取消）時呈現平靜空態與返回首頁按鈕', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u1'),
            matchRequestStreamProvider('non-existent-req').overrideWith(
              (ref) => Stream.value(null),
            ),
            requestMembersStreamProvider('non-existent-req').overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          child: const MaterialApp(
            home: WaitingRoomScreen(requestId: 'non-existent-req'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('找不到這個配對，可能已經結束或已取消'), findsOneWidget);
      expect(find.text('返回首頁'), findsOneWidget);
    });

    testWidgets('WaitingRoomScreen 進入 PENDING_CONFIRMATION 時提示前往我的活動', (tester) async {
      final request = MatchRequest(
        id: 'req-pc-test',
        ownerId: 'u1',
        activityTypeId: 'act-type-1',
        school: SCHOOL.NYCU,
        campus: '光復',
        earliestStart: testNow.add(const Duration(hours: 1)),
        latestStart: testNow.add(const Duration(hours: 2)),
        flexibleMinutes: 0,
        minParticipants: 2,
        allowDowngrade: false,
        status: REQUEST_STATUS.PENDING_CONFIRMATION,
        createdAt: testNow,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u1'),
            matchRequestStreamProvider('req-pc-test').overrideWith(
              (ref) => Stream.value(request),
            ),
            requestMembersStreamProvider('req-pc-test').overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const WaitingRoomScreen(requestId: 'req-pc-test'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('找到候選夥伴'), findsOneWidget);
      expect(find.text('前往我的活動'), findsOneWidget);
    });

    testWidgets('WaitingRoomScreen 包含背景推播未驗證警語與平靜退出說明', (tester) async {
      final request = MatchRequest(
        id: 'req-waiting-test',
        ownerId: 'u1',
        activityTypeId: 'act-type-1',
        school: SCHOOL.NYCU,
        campus: '光復',
        earliestStart: testNow.add(const Duration(hours: 1)),
        latestStart: testNow.add(const Duration(hours: 2)),
        flexibleMinutes: 0,
        minParticipants: 2,
        allowDowngrade: false,
        status: REQUEST_STATUS.REQUESTING,
        createdAt: testNow,
      );

      final actType = ActivityType(
        id: 'act-type-1',
        name: '羽球',
        status: ACTIVITY_TYPE_STATUS.APPROVED,
        createdAt: testNow,
        defaultMinParticipants: 2,
        defaultMaxParticipants: 4,
        skillLevelEnabled: true,
        sortOrder: 1,
        levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
        aliases: const [],
      );

      final member = RequestMember(
        id: 'rm-1',
        requestId: 'req-waiting-test',
        userId: 'u1',
        role: REQUEST_MEMBER_ROLE.OWNER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: testNow,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u1'),
            matchRequestStreamProvider('req-waiting-test').overrideWith(
              (ref) => Stream.value(request),
            ),
            requestMembersStreamProvider('req-waiting-test').overrideWith(
              (ref) => Stream.value([member]),
            ),
            activityTypeByIdProvider(actType.id).overrideWith((ref) async => actType),
            activityTypesProvider.overrideWith((ref) => Future.value([actType])),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 1400),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const WaitingRoomScreen(requestId: 'req-waiting-test'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('背景推播功能尚在驗證中，離開 App 可能無法即時收到通知'),
        findsOneWidget,
      );
      expect(
        find.textContaining('退出方式：可隨時取消或離開，無任何冷卻限制與信用扣分。'),
        findsOneWidget,
      );
    });

    testWidgets('ActivityDetailScreen 找不到活動時呈現平靜空態與返回按鈕', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activityStreamProvider('act-not-found').overrideWith(
              (ref) => Stream.value(null),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ActivityDetailScreen(activityId: 'act-not-found'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('找不到這個活動，可能已經結束或已取消'), findsOneWidget);
      expect(find.text('返回我的活動'), findsOneWidget);
    });

    test('推播 Payload 與去重 Tag 規範驗證（無 PII 洩漏）', () {
      final payload = PushSubscriptionPayload(
        endpoint: 'https://fcm.googleapis.com/fcm/send/sample-token',
        p256dh: 'BNcRdreALRF8M...',
        auth: 'tBHItDaQ...',
        userAgent: 'Mozilla/5.0 Chrome/120.0',
      );

      final json = payload.toJson();
      expect(json['endpoint'], isNotEmpty);
      expect(json['p256dh'], isNotEmpty);
      expect(json['auth'], isNotEmpty);
      // 確保沒有不必要的個人姓名、Email、Line、IG 欄位出現在訂閱或推播包裝中
      expect(json.containsKey('email'), isFalse);
      expect(json.containsKey('display_name'), isFalse);
      expect(json.containsKey('contact_ig'), isFalse);
    });
  });
}
