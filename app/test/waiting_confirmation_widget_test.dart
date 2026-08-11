import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/pending_confirmation_card.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_section.dart';
import 'package:find_people_now/widgets/app_status_summary.dart';

Widget _host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Widget _waitingRoomHost({
  required MatchRequest request,
  required ActivityType activityType,
}) {
  return ProviderScope(
    overrides: [
      matchRequestStreamProvider(
        request.id,
      ).overrideWith((ref) => Stream.value(request)),
      requestMembersStreamProvider(
        request.id,
      ).overrideWith((ref) => Stream.value(const [])),
      activityTypeByIdProvider(
        activityType.id,
      ).overrideWith((ref) async => activityType),
      currentUserIdProvider.overrideWith((ref) => null),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: WaitingRoomScreen(requestId: request.id),
    ),
  );
}

PendingConfirmationStatus _pendingStatus() => PendingConfirmationStatus(
  pendingConfirmationId: 'pending-1',
  status: PENDING_CONFIRMATION_STATUS.PENDING,
  confirmWindowExpireAt: DateTime.now().add(const Duration(minutes: 5)),
);

PendingConfirmationCandidateInfo _candidate() =>
    PendingConfirmationCandidateInfo(
      displayName: '候選夥伴',
      avatarUrl: '',
      school: SCHOOL.NYCU,
      department: '資訊工程學系',
      degreeLevel: DEGREE_LEVEL.MASTER,
      reliabilityTier: ReliabilityTier.normal,
      completedActivityCount: 3,
    );

void main() {
  testWidgets('200% 字級完整顯示等待條件的長活動名稱與長校區且不 ellipsis', (tester) async {
    const longType = '跨校創新創業與永續發展深度交流工作坊';
    const longCampus = '光復校區工程六館與綜合一館之間戶外創意交流廣場';
    final now = DateTime(2026, 8, 11, 9);
    final request = MatchRequest(
      id: 'long-waiting-copy',
      ownerId: 'owner',
      activityTypeId: 'long-type',
      earliestStart: now,
      latestStart: now.add(const Duration(hours: 1)),
      flexibleMinutes: 15,
      minParticipants: 3,
      maxParticipants: 5,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: now,
      school: SCHOOL.NYCU,
      campus: longCampus,
    );
    final type = ActivityType(
      id: 'long-type',
      name: longType,
      status: ACTIVITY_TYPE_STATUS.APPROVED,
      createdAt: now,
      skillLevelEnabled: false,
      sortOrder: 0,
    );

    await tester.pumpWidget(
      _waitingRoomHost(request: request, activityType: type),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final list = find.byType(Scrollable).first;
    for (final finder in [
      find.text(longType),
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains(longCampus) ?? false),
      ),
    ]) {
      await tester.scrollUntilVisible(finder, 240, scrollable: list);
      await tester.pump();
      expect(finder, findsOneWidget);
      final text = tester.widget<Text>(finder);
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(
        tester.renderObject<RenderParagraph>(finder).didExceedMaxLines,
        isFalse,
      );
      expect(finder.hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion uses a static matching glyph and survives runtime toggles',
    (tester) async {
      await tester.pumpWidget(
        _host(const MatchingPulse(), disableAnimations: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('配對中…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('matching-static-glyph')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('matching-animated-glyph')),
        findsNothing,
      );
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(_host(const MatchingPulse()));
      await tester.pump();
      expect(find.text('配對中…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('matching-animated-glyph')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        _host(const MatchingPulse(), disableAnimations: true),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('matching-static-glyph')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('matching-animated-glyph')),
        findsNothing,
      );
      expect(tester.binding.transientCallbackCount, 0);

      // A second enable on the same State reproduces the old
      // SingleTickerProviderStateMixin multiple-ticker assertion.
      await tester.pumpWidget(_host(const MatchingPulse()));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('matching-animated-glyph')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'waiting room production actions keep invite and owner controls',
    (tester) async {
      var generated = 0;
      var managed = 0;
      await tester.pumpWidget(
        _host(
          WaitingRoomActionSections(
            inviteToken: null,
            busy: false,
            isOwner: true,
            onGenerate: () => generated++,
            onCopy: () {},
            onRevoke: () {},
            onManage: () => managed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppSection), findsNWidgets(2));
      expect(find.text('邀請朋友'), findsNWidgets(2));
      expect(find.text('取消整個配對'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '邀請朋友'));
      await tester.tap(find.widgetWithText(OutlinedButton, '取消整個配對'));
      expect(generated, 1);
      expect(managed, 1);
    },
  );

  testWidgets('waiting room production actions keep copy, revoke, and leave', (
    tester,
  ) async {
    var copied = 0;
    var revoked = 0;
    var left = 0;
    await tester.pumpWidget(
      _host(
        WaitingRoomActionSections(
          inviteToken: 'invite-token-123',
          busy: false,
          isOwner: false,
          onGenerate: () {},
          onCopy: () => copied++,
          onRevoke: () => revoked++,
          onManage: () => left++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('invite-token-123'), findsOneWidget);
    expect(find.text('複製'), findsOneWidget);
    expect(find.text('撤銷'), findsOneWidget);
    expect(find.text('退出房間'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '複製'));
    await tester.tap(find.widgetWithText(OutlinedButton, '撤銷'));
    await tester.tap(find.widgetWithText(OutlinedButton, '退出房間'));
    expect(copied, 1);
    expect(revoked, 1);
    expect(left, 1);
  });

  testWidgets(
    'pending confirmation buttons are 44pt and single-flight while busy',
    (tester) async {
      final release = Completer<void>();
      var confirms = 0;
      var rejects = 0;
      await tester.pumpWidget(
        _host(
          PendingConfirmationStatusView(
            status: _pendingStatus(),
            candidate: _candidate(),
            busy: false,
            onConfirm: () async {
              confirms++;
              await release.future;
            },
            onReject: () async => rejects++,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppStatusSummary), findsOneWidget);
      expect(find.text(PendingConfirmationCopy.confirm), findsOneWidget);
      expect(find.text(PendingConfirmationCopy.reject), findsOneWidget);

      final confirmButton = find.widgetWithText(
        FilledButton,
        PendingConfirmationCopy.confirm,
      );
      final rejectButton = find.widgetWithText(
        OutlinedButton,
        PendingConfirmationCopy.reject,
      );
      await tester.ensureVisible(confirmButton);
      expect(tester.getSize(confirmButton).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(rejectButton).height, greaterThanOrEqualTo(44));

      await tester.tap(confirmButton);
      await tester.tap(confirmButton, warnIfMissed: false);
      await tester.pump();
      expect(confirms, 1);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );

      release.complete();
      await tester.pumpAndSettle();
      await tester.tap(rejectButton);
      await tester.pump();
      expect(rejects, 1);
    },
  );
}
