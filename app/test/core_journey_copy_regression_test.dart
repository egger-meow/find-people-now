import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:find_people_now/generated/activity_alert_subscription.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/app_user.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/create_request_screen.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_section.dart';
import 'package:find_people_now/widgets/app_selection_summary.dart';
import 'package:find_people_now/widgets/app_sticky_action_area.dart';

final _types = <ActivityType>[
  ActivityType(
    id: 'badminton',
    name: '羽球',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 3,
    defaultMaxParticipants: 5,
    groupSizeStep: 1,
    skillLevelEnabled: true,
    sortOrder: 1,
  ),
  ActivityType(
    id: 'study',
    name: '讀書',
    status: ACTIVITY_TYPE_STATUS.APPROVED,
    createdAt: DateTime(2026),
    defaultMinParticipants: 3,
    defaultMaxParticipants: 5,
    groupSizeStep: 1,
    skillLevelEnabled: false,
    sortOrder: 2,
  ),
];

final _user = AppUser(
  id: 'user-1',
  email: 'tester@nycu.edu.tw',
  school: SCHOOL.NYCU,
  displayName: '測試者',
  avatarUrl: 'https://example.com/avatar.png',
  bio: '',
  createdAt: DateTime(2026),
  degreeLevel: DEGREE_LEVEL.MASTER,
  defaultCampus: '光復',
);

final _fixedNow = DateTime(2026, 8, 11, 9, 17, 23, 456);
const _fixedWindowLabel = '今天 09:17 - 09:47';

class _CreateInvocation {
  const _CreateInvocation({
    required this.activityTypeId,
    required this.campus,
    required this.earliestStart,
    required this.latestStart,
    required this.minParticipants,
    required this.maxParticipants,
    required this.allowDowngrade,
    required this.skillLevel,
    required this.studyTarget,
  });

  final String activityTypeId;
  final String campus;
  final DateTime earliestStart;
  final DateTime latestStart;
  final int minParticipants;
  final int maxParticipants;
  final bool allowDowngrade;
  final SKILL_LEVEL? skillLevel;
  final String? studyTarget;
}

class _FakeSubmissionGateway
    implements MatchRequestSubmissionGateway, MatchRequestSubmissionSession {
  _FakeSubmissionGateway({this.createError, bool holdCreate = false})
    : _createCompleter = holdCreate ? Completer<MatchRequest>() : null;

  final ApiException? createError;
  static const requestId = 'request-exact-42';
  final Completer<MatchRequest>? _createCompleter;
  final calls = <String>[];
  final creates = <_CreateInvocation>[];
  final submittedRequestIds = <String>[];

  @override
  MatchRequestSubmissionSession capture(WidgetRef ref) => this;

  MatchRequest _request(REQUEST_STATUS status, _CreateInvocation invocation) =>
      MatchRequest(
        id: requestId,
        ownerId: _user.id,
        activityTypeId: invocation.activityTypeId,
        earliestStart: invocation.earliestStart,
        latestStart: invocation.latestStart,
        flexibleMinutes: 0,
        minParticipants: invocation.minParticipants,
        maxParticipants: invocation.maxParticipants,
        allowDowngrade: invocation.allowDowngrade,
        status: status,
        createdAt: DateTime(2026),
        school: SCHOOL.NYCU,
        campus: invocation.campus,
        skillLevel: invocation.skillLevel,
        studyTarget: invocation.studyTarget,
      );

  @override
  Future<MatchRequest> create({
    required String activityTypeId,
    required String campus,
    required DateTime earliestStart,
    required DateTime latestStart,
    required int minParticipants,
    required int maxParticipants,
    required bool allowDowngrade,
    required SKILL_LEVEL? skillLevel,
    required String? studyTarget,
  }) async {
    calls.add('create');
    final invocation = _CreateInvocation(
      activityTypeId: activityTypeId,
      campus: campus,
      earliestStart: earliestStart,
      latestStart: latestStart,
      minParticipants: minParticipants,
      maxParticipants: maxParticipants,
      allowDowngrade: allowDowngrade,
      skillLevel: skillLevel,
      studyTarget: studyTarget,
    );
    creates.add(invocation);
    if (createError != null) throw createError!;
    if (_createCompleter != null) return _createCompleter.future;
    return _request(REQUEST_STATUS.DRAFT, invocation);
  }

  @override
  Future<MatchRequest> submit(String requestId) async {
    calls.add('submit');
    submittedRequestIds.add(requestId);
    return _request(REQUEST_STATUS.REQUESTING, creates.single);
  }

  void completeCreate() {
    _createCompleter!.complete(_request(REQUEST_STATUS.DRAFT, creates.single));
  }
}

List<Override> _overrides({
  List<ActivityType>? types,
  AppUser? user,
  List<String>? campuses,
  bool isNewUser = false,
  VoidCallback? onActiveRequestLoad,
}) => [
  myActiveRequestProvider.overrideWith((ref) async {
    onActiveRequestLoad?.call();
    return null;
  }),
  myActiveActivityProvider.overrideWith((ref) async => null),
  activityTypesProvider.overrideWith((ref) async => types ?? _types),
  myAppUserProvider.overrideWith((ref) async => user ?? _user),
  campusOptionsProvider.overrideWith((ref, school) async => campuses ?? ['光復']),
  myReliabilityProvider.overrideWith(
    (ref) async => MyReliability(
      tier: isNewUser ? ReliabilityTier.newUser : ReliabilityTier.normal,
      isNewUser: isNewUser,
    ),
  ),
  campusPulseProvider.overrideWith(
    (ref, key) => Stream.value(const <CampusPulseEntry>[]),
  ),
  myActiveAlertSubscriptionsProvider.overrideWith(
    (ref) async => const <ActivityAlertSubscription>[],
  ),
];

Widget _host({
  TextScaler? textScaler,
  double bottomInset = 0,
  MatchRequestSubmissionGateway? gateway,
  GoRouter? router,
  List<ActivityType>? types,
  AppUser? user,
  List<String>? campuses,
  bool isNewUser = false,
  VoidCallback? onActiveRequestLoad,
  DateTime Function()? now,
}) {
  Widget mediaQueryBuilder(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: textScaler ?? TextScaler.noScaling,
      viewInsets: EdgeInsets.only(bottom: bottomInset),
    ),
    child: child!,
  );
  final app = router == null
      ? MaterialApp(
          theme: AppTheme.light,
          builder: mediaQueryBuilder,
          home: CreateRequestScreen(
            submissionGateway:
                gateway ?? const RpcMatchRequestSubmissionGateway(),
            now: now ?? DateTime.now,
          ),
        )
      : MaterialApp.router(
          theme: AppTheme.light,
          builder: mediaQueryBuilder,
          routerConfig: router,
        );
  return ProviderScope(
    key: UniqueKey(),
    overrides: _overrides(
      types: types,
      user: user,
      campuses: campuses,
      isNewUser: isNewUser,
      onActiveRequestLoad: onActiveRequestLoad,
    ),
    child: app,
  );
}

GoRouter _router(
  MatchRequestSubmissionGateway gateway, {
  DateTime Function()? now,
  bool watchActiveRequestOnAway = false,
}) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => CreateRequestScreen(
        submissionGateway: gateway,
        now: now ?? DateTime.now,
      ),
    ),
    GoRoute(
      path: '/waiting-room/:id',
      builder: (context, state) =>
          Scaffold(body: Text('等待室：${state.pathParameters['id']}')),
    ),
    GoRoute(
      path: '/away',
      builder: (context, state) => Consumer(
        builder: (context, ref, _) {
          if (watchActiveRequestOnAway) {
            ref.watch(myActiveRequestProvider);
          }
          return const Scaffold(body: Text('away'));
        },
      ),
    ),
  ],
);

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await _settle(tester);
}

Future<void> _scrollBackTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    -300,
    scrollable: find.byType(Scrollable).first,
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 3),
);

Future<void> _selectCompleteRequest(
  WidgetTester tester, {
  String activity = '羽球',
  String? skill,
  String? studyTarget,
  bool allowDowngrade = false,
}) async {
  await tester.tap(find.text(activity));
  await _settle(tester);
  if (skill != null || studyTarget != null) {
    await _scrollBackTo(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is AppSection && widget.title == '活動',
      ),
    );
  }
  if (skill != null) {
    await _scrollTo(tester, find.text(skill));
    await tester.tap(find.text(skill));
    await tester.pump();
  }
  if (studyTarget != null) {
    await _scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), studyTarget);
  }

  await _scrollTo(
    tester,
    find.byWidgetPredicate(
      (widget) => widget is AppSection && widget.title == '時間',
    ),
  );
  await tester.tap(find.text('現在'));
  await _settle(tester);

  await _scrollTo(tester, find.text('至少'));
  await tester.tap(find.widgetWithText(ChoiceChip, '3 人').first);
  await tester.pump();
  await tester.tap(find.widgetWithText(ChoiceChip, '5 人').last);
  await _settle(tester);

  if (allowDowngrade) {
    await _scrollTo(tester, find.text('人數不夠時，接受少一點人也算成局？'));
    await tester.tap(find.text('人數不夠時，接受少一點人也算成局？'));
    await _settle(tester);
  }
}

void main() {
  test('完整時間摘要會區分明天與今天', () {
    final today = DateTime(2026, 8, 11, 20);
    final tomorrowMorning = (
      DateTime(2026, 8, 12, 6),
      DateTime(2026, 8, 12, 12),
    );

    expect(
      formatMatchRequestWindow(tomorrowMorning, relativeTo: today),
      '明天 06:00 - 12:00',
    );
  });

  testWidgets('所有決策區塊與 disabled 原因維持可見繁中文字串', (tester) async {
    await tester.pumpWidget(
      _host(textScaler: TextScaler.linear(2), bottomInset: 160),
    );
    await _settle(tester);

    expect(find.textContaining('活動'), findsWidgets);
    expect(find.text('請先選擇活動'), findsOneWidget);
    expect(find.byType(AppStickyActionArea), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '送出，開始找人')).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getBottomRight(find.widgetWithText(FilledButton, '送出，開始找人')).dy,
      lessThanOrEqualTo(600 - 160),
    );

    for (final label in ['時間', '校區', '人數', '降級配對', '送出前確認']) {
      await _scrollTo(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is AppSection && widget.title == label,
        ),
      );
      expect(find.text(label), findsWidgets);
    }
    expect(find.textContaining('送出'), findsWidgets);
  });

  testWidgets('200% 字級完整顯示單一長校區名稱且不使用 ellipsis', (tester) async {
    const longCampus = '光復校區工程六館與綜合一館之間戶外創意交流廣場';
    await tester.pumpWidget(
      _host(
        textScaler: const TextScaler.linear(2),
        user: _user.copyWith(defaultCampus: longCampus),
        campuses: const [longCampus],
      ),
    );
    await _settle(tester);

    final campusLabel = find.text('校區：$longCampus');
    await _scrollTo(tester, campusLabel);
    expect(campusLabel, findsOneWidget);
    final text = tester.widget<Text>(campusLabel);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(
      tester.renderObject<RenderParagraph>(campusLabel).didExceedMaxLines,
      isFalse,
    );
    expect(tester.getSize(campusLabel).height, greaterThan(36));
    expect(campusLabel.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% 字級完整顯示長活動名稱且不使用 ellipsis', (tester) async {
    const longTypeName = '跨校創新創業與永續發展深度交流工作坊';
    final longType = ActivityType(
      id: 'long-type',
      name: longTypeName,
      status: ACTIVITY_TYPE_STATUS.APPROVED,
      createdAt: DateTime(2026),
      defaultMinParticipants: 3,
      defaultMaxParticipants: 5,
      groupSizeStep: 1,
      skillLevelEnabled: false,
      sortOrder: 1,
    );
    await tester.pumpWidget(
      _host(textScaler: const TextScaler.linear(2), types: [longType]),
    );
    await _settle(tester);

    final typeLabel = find.text(longTypeName);
    expect(typeLabel, findsOneWidget);
    final text = tester.widget<Text>(typeLabel);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(
      tester.renderObject<RenderParagraph>(typeLabel).didExceedMaxLines,
      isFalse,
    );
    expect(tester.getSize(typeLabel).height, greaterThan(36));
    expect(typeLabel.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('技能與讀書進階條件會依活動類型顯示', (tester) async {
    await tester.pumpWidget(_host());
    await _settle(tester);

    await tester.tap(find.text('羽球'));
    await tester.pump();
    expect(find.text('程度要求'), findsOneWidget);

    await _scrollTo(tester, find.text('讀書'));
    await tester.tap(find.text('讀書'));
    await tester.pump();
    expect(find.text('想找同樣在準備什麼的人？（選填）'), findsOneWidget);
    expect(find.text('科目/課程/考試名稱'), findsOneWidget);
  });

  testWidgets('摘要更新選擇，取消確認後保留內容', (tester) async {
    await tester.pumpWidget(_host(now: () => _fixedNow));
    await _settle(tester);
    await _selectCompleteRequest(tester, skill: '進階', allowDowngrade: true);
    await _scrollTo(tester, find.text('送出前確認'));

    expect(find.byType(AppSelectionSummary), findsOneWidget);
    expect(find.text('羽球'), findsWidgets);
    expect(find.text(_fixedWindowLabel), findsOneWidget);
    expect(find.text('光復'), findsWidgets);
    expect(find.text('最少 3 人，最多 5 人'), findsOneWidget);
    expect(find.text('進階'), findsWidgets);
    expect(find.text('接受'), findsOneWidget);

    await tester.tap(find.text('送出，開始找人'));
    await _settle(tester);
    expect(find.text('確認配對條件'), findsOneWidget);
    expect(find.text('確認送出'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    for (final value in ['羽球', '光復', '最少 3 人，最多 5 人', '進階', '接受']) {
      expect(find.text(value), findsWidgets);
    }
    expect(find.text(_fixedWindowLabel), findsWidgets);

    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(find.text('最少 3 人，最多 5 人'), findsOneWidget);
    expect(find.text('進階'), findsWidgets);
    expect(find.text('接受'), findsOneWidget);
    expect(find.text(_fixedWindowLabel), findsOneWidget);
  });

  testWidgets('正向確認只送出一次並保留 screen RPC contract 與順序', (tester) async {
    final gateway = _FakeSubmissionGateway(holdCreate: true);
    final router = _router(gateway, now: () => _fixedNow);
    addTearDown(router.dispose);
    var activeRequestLoads = 0;

    await tester.pumpWidget(
      _host(
        gateway: gateway,
        router: router,
        onActiveRequestLoad: () => activeRequestLoads++,
      ),
    );
    await _settle(tester);
    await _selectCompleteRequest(tester, skill: '進階', allowDowngrade: true);

    await _scrollTo(tester, find.text('送出前確認'));
    expect(find.text(_fixedWindowLabel), findsOneWidget);
    final primaryOnPressed = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '送出，開始找人'))
        .onPressed!;
    primaryOnPressed();
    primaryOnPressed();
    await tester.pump();
    await _settle(tester);
    expect(find.text('確認配對條件'), findsOneWidget);
    expect(find.text(_fixedWindowLabel), findsWidgets);

    await tester.tap(find.text('確認送出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.calls, ['create']);
    expect(gateway.creates, hasLength(1));

    primaryOnPressed();
    await tester.pump();
    expect(find.text('確認配對條件'), findsNothing);
    expect(gateway.calls, ['create']);

    gateway.completeCreate();
    await _settle(tester);

    expect(gateway.calls, ['create', 'submit']);
    expect(gateway.creates, hasLength(1));
    expect(gateway.submittedRequestIds, ['request-exact-42']);
    final invocation = gateway.creates.single;
    expect(invocation.activityTypeId, 'badminton');
    expect(invocation.campus, '光復');
    expect(invocation.earliestStart, _fixedNow.toUtc());
    expect(
      invocation.latestStart,
      _fixedNow.add(const Duration(minutes: 30)).toUtc(),
    );
    expect(invocation.minParticipants, 3);
    expect(invocation.maxParticipants, 5);
    expect(invocation.allowDowngrade, isTrue);
    expect(invocation.skillLevel, SKILL_LEVEL.ADVANCED);
    expect(invocation.studyTarget, isNull);
    expect(activeRequestLoads, greaterThanOrEqualTo(2));
    expect(find.text('等待室：request-exact-42'), findsOneWidget);
  });

  testWidgets('create 期間離開畫面仍用已捕獲 session submit 且不重新導航', (tester) async {
    final gateway = _FakeSubmissionGateway(holdCreate: true);
    final router = _router(
      gateway,
      now: () => _fixedNow,
      watchActiveRequestOnAway: true,
    );
    addTearDown(router.dispose);
    var activeRequestLoads = 0;

    await tester.pumpWidget(
      _host(
        gateway: gateway,
        router: router,
        onActiveRequestLoad: () => activeRequestLoads++,
      ),
    );
    await _settle(tester);
    await _selectCompleteRequest(tester);
    await tester.tap(find.text('送出，開始找人'));
    await _settle(tester);
    await tester.tap(find.text('確認送出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.calls, ['create']);

    router.go('/away');
    await _settle(tester);
    expect(find.text('away'), findsOneWidget);
    final loadsBeforeSubmit = activeRequestLoads;

    gateway.completeCreate();
    await _settle(tester);

    expect(gateway.calls, ['create', 'submit']);
    expect(gateway.submittedRequestIds, ['request-exact-42']);
    expect(activeRequestLoads, greaterThan(loadsBeforeSubmit));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/away');
  });

  testWidgets('讀書確認包含時間、科目與全部共同條件', (tester) async {
    await tester.pumpWidget(_host(now: () => _fixedNow));
    await _settle(tester);
    await _selectCompleteRequest(tester, activity: '讀書', studyTarget: '微積分（一）');

    await tester.tap(find.text('送出，開始找人'));
    await _settle(tester);

    expect(find.text('確認配對條件'), findsOneWidget);
    for (final value in ['讀書', '光復', '最少 3 人，最多 5 人', '微積分（一）', '不接受']) {
      expect(find.text(value), findsWidgets);
    }
    expect(find.text('讀書條件'), findsWidgets);
    expect(find.text('降級配對'), findsWidgets);
    expect(find.text(_fixedWindowLabel), findsWidgets);

    await tester.tap(find.text('取消'));
    await _settle(tester);
  });

  testWidgets('既有 custom-time、helper 與 reliability restriction 文案可觸發', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await _settle(tester);
    await _scrollTo(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is AppSection && widget.title == '時間',
      ),
    );
    await tester.tap(find.text('自訂時間'));
    await tester.pump();
    expect(find.text('最早開始時間'), findsOneWidget);
    expect(find.text('最晚開始時間'), findsOneWidget);

    await _scrollTo(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is AppSection && widget.title == '人數',
      ),
    );
    expect(find.text('人數是整團的總人數，含你自己'), findsOneWidget);

    final restrictedType = _types.first.copyWith(
      defaultMinParticipants: 2,
      defaultMaxParticipants: 4,
    );
    await tester.pumpWidget(_host(types: [restrictedType], isNewUser: true));
    await _settle(tester);
    await tester.tap(find.text('羽球'));
    await _settle(tester);
    await _scrollTo(tester, find.text('至少'));
    expect(find.text('新用戶需要先完成一次活動、建立信譽後，才能發起 2 人以下的小型場次'), findsOneWidget);
  });

  testWidgets('cooldown 與 submit error 繁中文案維持 UI 可達', (tester) async {
    final cooldownUser = _user.copyWith(
      nextRequestAllowedAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    await tester.pumpWidget(_host(user: cooldownUser));
    await _settle(tester);
    expect(find.text('配對冷卻中（無法建立新配對）'), findsOneWidget);
    expect(find.textContaining('剩餘時間：'), findsOneWidget);
    expect(find.text('配對冷卻中，暫時無法送出'), findsWidgets);

    final gateway = _FakeSubmissionGateway(
      createError: ApiException(
        code: ApiErrorCode.invalidInput,
        rawMessage: 'INVALID_INPUT',
        detail: '測試細節',
      ),
    );
    await tester.pumpWidget(_host(gateway: gateway));
    await _settle(tester);
    await _selectCompleteRequest(tester);
    await tester.tap(find.text('送出，開始找人'));
    await _settle(tester);
    await tester.tap(find.text('確認送出'));
    await _settle(tester);

    expect(find.text('部分資料不正確，請檢查後再試'), findsOneWidget);
    expect(find.textContaining('invalidInput'), findsNothing);
    expect(find.textContaining('測試細節'), findsNothing);
    expect(gateway.calls, ['create']);
  });
}
