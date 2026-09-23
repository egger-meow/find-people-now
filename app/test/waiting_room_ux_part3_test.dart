import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:find_people_now/widgets/countdown_text.dart';

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

  testWidgets('等待室包含 RefreshIndicator 且下拉能觸發刷新', (tester) async {
    final request = MatchRequest(
      id: 'req-refresh-test',
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
      requestId: 'req-refresh-test',
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

    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('成員超過 5 人時顯示 +N 匿名標記', (tester) async {
    final request = MatchRequest(
      id: 'req-many-members',
      ownerId: 'u1',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.add(const Duration(hours: 1)),
      latestStart: now.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 4,
      maxParticipants: 8,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: now,
    );

    final members = List.generate(
      7,
      (i) => RequestMember(
        id: 'm$i',
        requestId: 'req-many-members',
        userId: 'u$i',
        role: i == 0 ? REQUEST_MEMBER_ROLE.OWNER : REQUEST_MEMBER_ROLE.MEMBER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      ),
    );

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: members,
        currentUserId: 'u0',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('房間成員 · 目前 7 人（含你）'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
  });

  testWidgets('等待室取消配對（發起人）確認對話框包含完整無扣分文案', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final request = MatchRequest(
      id: 'req-cancel-copy',
      ownerId: 'u-owner',
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
      id: 'm-owner',
      requestId: 'req-cancel-copy',
      userId: 'u-owner',
      role: REQUEST_MEMBER_ROLE.OWNER,
      status: REQUEST_MEMBER_STATUS.JOINED,
      createdAt: now,
    );

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: [member],
        currentUserId: 'u-owner',
      ),
    );
    await tester.pumpAndSettle();

    final cancelButton = find.widgetWithText(OutlinedButton, '取消整個配對');
    await tester.ensureVisible(cancelButton);
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(find.text('確定要取消配對？'), findsOneWidget);
    expect(
      find.text('取消後將退出本次配對等待，房間將關閉。\n\n此操作不會有冷卻時間或信譽扣分。'),
      findsOneWidget,
    );
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('確定取消'), findsOneWidget);
  });

  testWidgets('等待室退出房間（成員）確認對話框包含完整退出說明', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final request = MatchRequest(
      id: 'req-leave-copy',
      ownerId: 'u-owner',
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

    final members = [
      RequestMember(
        id: 'm-owner',
        requestId: 'req-leave-copy',
        userId: 'u-owner',
        role: REQUEST_MEMBER_ROLE.OWNER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      ),
      RequestMember(
        id: 'm-guest',
        requestId: 'req-leave-copy',
        userId: 'u-guest',
        role: REQUEST_MEMBER_ROLE.MEMBER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      ),
    ];

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: members,
        currentUserId: 'u-guest',
      ),
    );
    await tester.pumpAndSettle();

    final leaveButton = find.widgetWithText(OutlinedButton, '退出房間');
    await tester.ensureVisible(leaveButton);
    await tester.pumpAndSettle();
    await tester.tap(leaveButton);
    await tester.pumpAndSettle();

    expect(find.text('確定要退出等待？'), findsOneWidget);
    expect(
      find.text('取消後將退出本次配對等待，其他等待中的夥伴將繼續等待。\n\n此操作不會有冷卻時間或信譽扣分。'),
      findsOneWidget,
    );
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('確定退出'), findsOneWidget);
  });

  testWidgets('CountdownText 支援自訂 expiredLabel 正在確認配對結果', (tester) async {
    final past = DateTime.now().subtract(const Duration(seconds: 5));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CountdownText(
            deadline: past,
            expiredLabel: '正在確認配對結果',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('正在確認配對結果'), findsOneWidget);
  });

  testWidgets('等待室進入已被撤銷的房間時，不顯示失效邀請碼，房主顯示「邀請碼已撤銷」與重新產生按鈕', (tester) async {
    final revokedTime = now.subtract(const Duration(minutes: 10));
    final request = MatchRequest(
      id: 'req-revoked-owner',
      ownerId: 'u-owner',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.add(const Duration(hours: 1)),
      latestStart: now.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      inviteToken: 'stale-revoked-token',
      revokedAt: revokedTime,
      createdAt: now,
    );

    final member = RequestMember(
      id: 'm-owner',
      requestId: 'req-revoked-owner',
      userId: 'u-owner',
      role: REQUEST_MEMBER_ROLE.OWNER,
      status: REQUEST_MEMBER_STATUS.JOINED,
      createdAt: now,
    );

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: [member],
        currentUserId: 'u-owner',
      ),
    );
    await tester.pumpAndSettle();

    // Stale token must NEVER be visible
    expect(find.text('stale-revoked-token'), findsNothing);

    // Revocation status and regenerate button must be visible for owner
    expect(find.text('邀請碼已撤銷'), findsOneWidget);
    expect(
      find.text('目前的邀請碼已失效，朋友無法透過舊連結加入。如需再次邀請，請重新產生。'),
      findsOneWidget,
    );
    expect(find.text('重新產生邀請碼'), findsOneWidget);
  });

  testWidgets('等待室非房主進入已被撤銷的房間時，顯示「邀請碼已被房主撤銷」且無重新產生按鈕', (tester) async {
    final revokedTime = now.subtract(const Duration(minutes: 10));
    final request = MatchRequest(
      id: 'req-revoked-guest',
      ownerId: 'u-owner',
      activityTypeId: 'act-type-1',
      school: SCHOOL.NYCU,
      campus: '光復',
      earliestStart: now.add(const Duration(hours: 1)),
      latestStart: now.add(const Duration(hours: 2)),
      flexibleMinutes: 0,
      minParticipants: 2,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      inviteToken: 'stale-revoked-token',
      revokedAt: revokedTime,
      createdAt: now,
    );

    final members = [
      RequestMember(
        id: 'm-owner',
        requestId: 'req-revoked-guest',
        userId: 'u-owner',
        role: REQUEST_MEMBER_ROLE.OWNER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      ),
      RequestMember(
        id: 'm-guest',
        requestId: 'req-revoked-guest',
        userId: 'u-guest',
        role: REQUEST_MEMBER_ROLE.MEMBER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      ),
    ];

    await tester.pumpWidget(
      createSubject(
        request: request,
        members: members,
        currentUserId: 'u-guest',
      ),
    );
    await tester.pumpAndSettle();

    // Stale token must NEVER be visible
    expect(find.text('stale-revoked-token'), findsNothing);

    // Member sees revoked notice, but NO regenerate button
    expect(find.text('邀請碼已被房主撤銷'), findsOneWidget);
    expect(find.text('重新產生邀請碼'), findsNothing);
  });
}
