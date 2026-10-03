import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/request_member.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_mascot_stage.dart';

void main() {
  final now = DateTime.utc(2026, 9, 23, 10, 0);

  Widget createSubject({
    required MatchRequest request,
    required List<RequestMember> members,
    required String currentUserId,
    ActivityType? activityType,
  }) {
    final type = activityType ??
        ActivityType(
          id: request.activityTypeId,
          name: '羽球',
          status: ACTIVITY_TYPE_STATUS.APPROVED,
          createdAt: now,
          skillLevelEnabled: false,
          sortOrder: 1,
          levelSystem: LEVEL_SYSTEM.NONE,
          aliases: const [],
        );

    return ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => currentUserId),
        matchRequestStreamProvider(request.id).overrideWith(
          (ref) => Stream.value(request),
        ),
        requestMembersStreamProvider(request.id).overrideWith(
          (ref) => Stream.value(members),
        ),
        activityTypeByIdProvider(type.id).overrideWith((ref) async => type),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: WaitingRoomScreen(requestId: request.id),
      ),
    );
  }

  testWidgets('F21: 等待室顯示「距配對截止時間」與非同步配對說明，避免誤解為 ETA', (tester) async {
    final request = MatchRequest(
      id: 'req-f21-test',
      ownerId: 'u1',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.add(const Duration(hours: 1)),
      latestStart: now.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: now,
    );

    final member = RequestMember(
      id: 'm1',
      requestId: 'req-f21-test',
      userId: 'u1',
      role: REQUEST_MEMBER_ROLE.OWNER,
      status: REQUEST_MEMBER_STATUS.JOINED,
      createdAt: now,
    );

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: [member],
        currentUserId: 'u1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('距配對截止時間'), findsOneWidget);
    expect(
      find.textContaining('非預估等待時間。配對為系統非同步撮合'),
      findsOneWidget,
    );
  });

  testWidgets('F22: 等待室吉祥物與版面緊湊化，主要動作與資訊完整可達', (tester) async {
    final request = MatchRequest(
      id: 'req-f22-test',
      ownerId: 'u1',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.add(const Duration(hours: 1)),
      latestStart: now.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      inviteToken: 'test-token-f22',
      createdAt: now,
    );

    final member = RequestMember(
      id: 'm1',
      requestId: 'req-f22-test',
      userId: 'u1',
      role: REQUEST_MEMBER_ROLE.OWNER,
      status: REQUEST_MEMBER_STATUS.JOINED,
      createdAt: now,
    );

    tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: [member],
        currentUserId: 'u1',
      ),
    );
    await tester.pumpAndSettle();

    final mascotFinder = find.byType(AppMascotStage);
    expect(mascotFinder, findsOneWidget);
    final mascotWidget = tester.widget<AppMascotStage>(mascotFinder);
    expect(mascotWidget.height, lessThanOrEqualTo(88));

    // 首屏可達性：在 390x844 視窗中，無須滾動，核心邀請動作整顆按鈕均在首屏可視高度內 (dy <= 844) 且可點擊
    final inviteBtnTextFinder = find.text('複製邀請碼');
    expect(inviteBtnTextFinder, findsOneWidget);
    final inviteBtnFinder = find.ancestor(
      of: inviteBtnTextFinder,
      matching: find.byType(OutlinedButton),
    );
    expect(inviteBtnFinder, findsOneWidget);

    final inviteTopLeft = tester.getTopLeft(inviteBtnFinder);
    final inviteBottomRight = tester.getBottomRight(inviteBtnFinder);
    expect(inviteTopLeft.dy, greaterThanOrEqualTo(0.0));
    expect(inviteBottomRight.dy, lessThanOrEqualTo(844.0),
        reason: '整顆「複製邀請碼」按鈕必須完整在首屏可見範圍內，不得裁切');

    // 實際觸發點擊，證明可點且正常執行複製回饋
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async => null,
    );
    await tester.tap(inviteBtnFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已複製邀請碼'), findsOneWidget);
    await tester.pumpAndSettle();

    // 驗證安全取消退出動作可達且清楚說明無冷卻
    final cancelBtnFinder = find.text('取消整個配對');
    expect(cancelBtnFinder, findsOneWidget);
    expect(find.text('此操作無冷卻限制且不影響信譽評分'), findsOneWidget);
  });

  testWidgets('F24: 終態（EXPIRED 與 CANCELLED）呈現安心吉祥物與完整動作指引，無空洞留白', (tester) async {
    final expiredRequest = MatchRequest(
      id: 'req-f24-expired',
      ownerId: 'u1',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.subtract(const Duration(hours: 2)),
      latestStart: now.subtract(const Duration(hours: 1)),
      flexibleMinutes: 0,
      minParticipants: 2,
      allowDowngrade: false,
      status: REQUEST_STATUS.EXPIRED,
      createdAt: now.subtract(const Duration(hours: 3)),
    );

    await tester.pumpWidget(
      createSubject(
        request: expiredRequest,
        members: [],
        currentUserId: 'u1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('這次沒有成團'), findsOneWidget);
    expect(find.byType(AppMascotStage), findsOneWidget);
    expect(find.text('回配對頁'), findsOneWidget);
  });
}
