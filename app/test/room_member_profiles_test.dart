import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/request_member.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/invite_friends_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final now = DateTime.utc(2026, 10, 3, 12, 0);

  group('RequestMemberProfile JSON parsing', () {
    test('parses full json correctly', () {
      final json = {
        'user_id': 'u1',
        'display_name': '小明',
        'avatar_url': 'https://example.com/avatar.jpg',
        'role': 'OWNER',
        'status': 'JOINED',
        'created_at': '2026-10-03T12:00:00.000Z',
      };
      final profile = RequestMemberProfile.fromJson(json);
      expect(profile.userId, 'u1');
      expect(profile.displayName, '小明');
      expect(profile.avatarUrl, 'https://example.com/avatar.jpg');
      expect(profile.role, REQUEST_MEMBER_ROLE.OWNER);
      expect(profile.status, REQUEST_MEMBER_STATUS.JOINED);
      expect(profile.createdAt, DateTime.parse('2026-10-03T12:00:00.000Z'));
    });

    test('falls back to default display_name when null or empty', () {
      final json = {
        'user_id': 'u2',
        'display_name': '',
        'avatar_url': null,
        'role': 'MEMBER',
        'status': 'JOINED',
        'created_at': '2026-10-03T12:00:00.000Z',
      };
      final profile = RequestMemberProfile.fromJson(json);
      expect(profile.displayName, '夥伴');
      expect(profile.avatarUrl, isNull);
    });
  });

  group('RoomMemberAvatar widget', () {
    testWidgets('renders real display_name and (你) for self', (tester) async {
      final profile = RequestMemberProfile(
        userId: 'u-self',
        displayName: '小明',
        avatarUrl: null,
        role: REQUEST_MEMBER_ROLE.MEMBER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: RoomMemberAvatar(
              profile: profile,
              isSelf: true,
              isOwner: false,
            ),
          ),
        ),
      );

      expect(find.text('小明 (你)'), findsOneWidget);
      // Fallback letter is displayed
      expect(find.text('小'), findsOneWidget);
    });

    testWidgets('renders gold star icon for room owner', (tester) async {
      final profile = RequestMemberProfile(
        userId: 'u-owner',
        displayName: '房長',
        avatarUrl: null,
        role: REQUEST_MEMBER_ROLE.OWNER,
        status: REQUEST_MEMBER_STATUS.JOINED,
        createdAt: now,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: RoomMemberAvatar(
              profile: profile,
              isSelf: false,
              isOwner: true,
            ),
          ),
        ),
      );

      expect(find.text('房長'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });
  });

  group('RoomMembersSection widget', () {
    testWidgets('renders joined members with their real profiles', (tester) async {
      final members = [
        RequestMember(
          id: 'rm-1',
          requestId: 'req-1',
          userId: 'u-owner',
          role: REQUEST_MEMBER_ROLE.OWNER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now,
        ),
        RequestMember(
          id: 'rm-2',
          requestId: 'req-1',
          userId: 'u-friend',
          role: REQUEST_MEMBER_ROLE.MEMBER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now.add(const Duration(minutes: 5)),
        ),
      ];

      final profiles = [
        RequestMemberProfile(
          userId: 'u-owner',
          displayName: '小明',
          avatarUrl: null,
          role: REQUEST_MEMBER_ROLE.OWNER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now,
        ),
        RequestMemberProfile(
          userId: 'u-friend',
          displayName: '小華',
          avatarUrl: null,
          role: REQUEST_MEMBER_ROLE.MEMBER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now.add(const Duration(minutes: 5)),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u-owner'),
            requestMembersStreamProvider('req-1').overrideWith(
              (ref) => Stream.value(members),
            ),
            requestMemberProfilesProvider('req-1').overrideWith(
              (ref) async => profiles,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: RoomMembersSection(
                requestId: 'req-1',
                members: members,
                currentUserId: 'u-owner',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('房間成員 · 目前 2 人（含你）'), findsOneWidget);
      expect(find.text('小明 (你)'), findsOneWidget);
      expect(find.text('小華'), findsOneWidget);
    });
  });

  group('InviteFriendsScreen companion visibility', () {
    testWidgets('displays joined friend with real profile before starting match', (tester) async {
      final draft = MatchRequest(
        id: 'draft-1',
        ownerId: 'u-owner',
        activityTypeId: 'act-1',
        school: SCHOOL.NYCU,
        campus: '光復',
        status: REQUEST_STATUS.DRAFT,
        earliestStart: now,
        latestStart: now.add(const Duration(hours: 2)),
        flexibleMinutes: 0,
        minParticipants: 2,
        maxParticipants: 4,
        allowDowngrade: false,
        createdAt: now,
      );

      final members = [
        RequestMember(
          id: 'rm-1',
          requestId: 'draft-1',
          userId: 'u-owner',
          role: REQUEST_MEMBER_ROLE.OWNER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now,
        ),
        RequestMember(
          id: 'rm-2',
          requestId: 'draft-1',
          userId: 'u-friend',
          role: REQUEST_MEMBER_ROLE.MEMBER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now.add(const Duration(minutes: 1)),
        ),
      ];

      final profiles = [
        RequestMemberProfile(
          userId: 'u-owner',
          displayName: 'test1',
          avatarUrl: null,
          role: REQUEST_MEMBER_ROLE.OWNER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now,
        ),
        RequestMemberProfile(
          userId: 'u-friend',
          displayName: 'test2',
          avatarUrl: null,
          role: REQUEST_MEMBER_ROLE.MEMBER,
          status: REQUEST_MEMBER_STATUS.JOINED,
          createdAt: now.add(const Duration(minutes: 1)),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWith((ref) => 'u-owner'),
            matchRequestStreamProvider('draft-1').overrideWith(
              (ref) => Stream.value(draft),
            ),
            requestMembersStreamProvider('draft-1').overrideWith(
              (ref) => Stream.value(members),
            ),
            requestMemberProfilesProvider('draft-1').overrideWith(
              (ref) async => profiles,
            ),
          ],
          child: const MaterialApp(
            home: InviteFriendsScreen(requestId: 'draft-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('目前 2 人（含發起人）'), findsOneWidget);
      expect(find.text('test1 (你)'), findsOneWidget);
      expect(find.text('test2'), findsOneWidget);
      expect(find.text('人都進來了，開始配對'), findsOneWidget);
    });
  });
}
