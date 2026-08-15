import 'package:find_people_now/activities/my_activities_providers.dart';
import 'package:find_people_now/activities/my_activities_screen.dart';
import 'package:find_people_now/activities/pending_confirmation_card.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/theme/app_theme.dart';
import 'package:find_people_now/widgets/app_status_summary.dart';
import 'package:find_people_now/widgets/skeleton.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _now = DateTime.utc(2026, 8, 11, 9);

ActivityType _type(String id, String name) => ActivityType(
  id: id,
  name: name,
  status: ACTIVITY_TYPE_STATUS.APPROVED,
  createdAt: _now,
  skillLevelEnabled: false,
  sortOrder: 0,
  levelSystem: LEVEL_SYSTEM.NONE,
  aliases: const [],
);

MatchRequest _request(String id, REQUEST_STATUS status, String typeId) =>
    MatchRequest(
      id: id,
      ownerId: 'member',
      activityTypeId: typeId,
      earliestStart: _now,
      latestStart: _now.add(const Duration(hours: 1)),
      flexibleMinutes: 15,
      minParticipants: 2,
      allowDowngrade: false,
      status: status,
      createdAt: _now,
      school: SCHOOL.NYCU,
      campus: 'Main',
    );

Activity _activity(
  String id,
  ACTIVITY_STATUS status,
  String typeId, {
  String campus = 'Main',
  DateTime? startTime,
}) => Activity(
  id: id,
  activityTypeId: typeId,
  startTime: startTime ?? _now,
  estimatedEndTime: (startTime ?? _now).add(const Duration(hours: 1)),
  status: status,
  contactVisibleUntil: _now.add(const Duration(days: 1)),
  createdAt: _now,
  school: SCHOOL.NYCU,
  campus: campus,
);

Widget _host({
  required Future<List<MyActivityListItem>> Function(Ref ref) loadItems,
  required GoRouter router,
  List<ActivityType> types = const [],
  AsyncValue<List<MyActivityListItem>>? listState,
  MediaQueryData mediaQueryData = const MediaQueryData(),
}) {
  return ProviderScope(
    key: ValueKey(router),
    overrides: [
      if (listState == null)
        myActivityListProvider.overrideWith(loadItems)
      else
        myActivityListProvider.overrideWithValue(listState),
      activityTypesProvider.overrideWith((ref) async => types),
      supabaseClientProvider.overrideWithValue(
        SupabaseClient(
          'http://127.0.0.1:65535',
          'test-anon-key',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        ),
      ),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: mediaQueryData,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

GoRouter _router() => GoRouter(
  initialLocation: '/my-activities',
  routes: [
    GoRoute(
      path: '/my-activities',
      builder: (_, _) => const MyActivitiesScreen(),
    ),
    GoRoute(
      path: '/waiting-room/:id',
      builder: (_, state) => Text('waiting-${state.pathParameters['id']}'),
    ),
    GoRoute(
      path: '/activity/:id',
      builder: (_, state) => Text('activity-${state.pathParameters['id']}'),
    ),
    GoRoute(path: '/match', builder: (_, _) => const Text('match')),
  ],
);

void main() {
  testWidgets('iOS segmented control 本體與語意點擊區都至少 44pt', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          router: _router(),
          loadItems: (_) async => [],
          mediaQueryData: const MediaQueryData(size: Size(390, 844)),
        ),
      );
      await tester.pumpAndSettle();

      final segmented = find.byType(CupertinoSlidingSegmentedControl<int>);
      expect(segmented, findsOneWidget);
      expect(tester.getSize(segmented).height, greaterThanOrEqualTo(52));
      for (final label in ['進行中', '已結束']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)).rect.height,
          greaterThanOrEqualTo(44),
        );
      }
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('200% 字級完整顯示長活動名稱、時間與長校區且不使用 ellipsis', (tester) async {
    const longType = '跨校創新創業與永續發展深度交流工作坊';
    const longCampus = '光復校區工程六館與綜合一館之間戶外交流廣場';
    final activity = _activity(
      'long-copy',
      ACTIVITY_STATUS.MATCHED,
      'long-type',
      campus: longCampus,
      startTime: DateTime(2040, 8, 30, 9),
    );

    await tester.pumpWidget(
      _host(
        router: _router(),
        types: [_type('long-type', longType)],
        loadItems: (_) async => [MyActivityListItem.activity(activity)],
        mediaQueryData: const MediaQueryData(
          size: Size(375, 812),
          textScaler: TextScaler.linear(2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final criticalFinders = [
      find.text(longType),
      find.text('8/30 09:00'),
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains(longCampus) ?? false),
      ),
    ];
    for (final finder in criticalFinders) {
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
    'production screen prioritizes actionable activities with single semantic controls',
    (tester) async {
      final router = _router();
      final items = [
        MyActivityListItem.request(
          _request('pending', REQUEST_STATUS.PENDING_CONFIRMATION, 'coffee'),
        ),
        MyActivityListItem.activity(
          _activity('ongoing', ACTIVITY_STATUS.ONGOING, 'coffee'),
        ),
        MyActivityListItem.request(
          _request('requesting', REQUEST_STATUS.REQUESTING, 'study'),
        ),
        MyActivityListItem.activity(
          _activity('upcoming', ACTIVITY_STATUS.MATCHED, 'coffee'),
        ),
        MyActivityListItem.activity(
          _activity('completed', ACTIVITY_STATUS.COMPLETED, 'coffee'),
        ),
      ];
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        _host(
          router: router,
          types: [_type('coffee', 'Coffee'), _type('study', 'Study')],
          loadItems: (_) async => items,
          mediaQueryData: const MediaQueryData(
            textScaler: TextScaler.linear(2),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PendingConfirmationCard), findsOneWidget);
      expect(find.byType(AppStatusSummary), findsOneWidget);
      expect(find.text('進行中'), findsOneWidget);
      expect(find.text('已成團，等待開始'), findsOneWidget);
      expect(find.textContaining('Main'), findsWidgets);
      expect(
        tester.getTopLeft(find.text('需要處理')).dy,
        lessThan(tester.getTopLeft(find.text('目前活動')).dy),
      );
      expect(find.byType(ExcludeSemantics), findsAtLeastNWidgets(2));
      expect(find.bySemanticsLabel(RegExp('Coffee.*進行中')), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'outer semantics expose and perform request and activity tap actions',
    (tester) async {
      final router = _router();
      final items = [
        MyActivityListItem.request(
          _request('requesting', REQUEST_STATUS.REQUESTING, 'study'),
        ),
        MyActivityListItem.activity(
          _activity('upcoming', ACTIVITY_STATUS.MATCHED, 'coffee'),
        ),
      ];

      await tester.pumpWidget(
        _host(
          router: router,
          types: [_type('coffee', 'Coffee'), _type('study', 'Study')],
          loadItems: (_) async => items,
        ),
      );
      await tester.pumpAndSettle();

      final semantics = tester.ensureSemantics();
      final requestControl = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.label?.contains('Study') ?? false),
      );
      final requestNode = tester.getSemantics(requestControl);
      final requestLabel = requestNode.getSemanticsData().label;
      expect(
        requestNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      tester.semantics.performAction(
        find.semantics.byLabel(requestLabel),
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.text('waiting-requesting'), findsOneWidget);

      router.go('/my-activities');
      await tester.pumpAndSettle();
      final activityControl = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.label?.contains('Coffee') ?? false),
      );
      final activityNode = tester.getSemantics(activityControl);
      final activityLabel = activityNode.getSemanticsData().label;
      expect(
        activityNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      tester.semantics.performAction(
        find.semantics.byLabel(activityLabel),
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.text('activity-upcoming'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets(
    'provider-backed empty tabs retain their production CTA and history copy',
    (tester) async {
      await tester.pumpWidget(
        _host(router: _router(), loadItems: (_) async => []),
      );
      await tester.pumpAndSettle();

      expect(find.text('目前沒有進行中的活動'), findsOneWidget);
      expect(find.text('找人一起做點事'), findsOneWidget);

      await tester.tap(find.text('已結束'));
      await tester.pumpAndSettle();
      expect(find.text('還沒有已結束的活動\n完成的活動會出現在這裡'), findsOneWidget);
    },
  );

  testWidgets(
    'tabs, refresh, and async states remain available on the production screen',
    (tester) async {
      var loads = 0;
      final router = _router();
      final items = [
        MyActivityListItem.activity(
          _activity('completed', ACTIVITY_STATUS.COMPLETED, 'coffee'),
        ),
      ];

      await tester.pumpWidget(
        _host(
          router: router,
          types: [_type('coffee', 'Coffee')],
          loadItems: (_) async {
            loads++;
            return items;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已結束'));
      await tester.pumpAndSettle();
      expect(find.text('過去活動'), findsOneWidget);

      await tester.fling(
        find.byType(CustomScrollView).last,
        const Offset(0, 400),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(loads, greaterThanOrEqualTo(2));

      await tester.pumpWidget(
        _host(
          router: _router(),
          loadItems: (_) async => [],
          listState: const AsyncLoading(),
        ),
      );
      await tester.pump();
      expect(
        find.byType(ActivityListSkeleton, skipOffstage: false),
        findsWidgets,
      );

      await tester.pumpWidget(
        _host(
          router: _router(),
          loadItems: (_) async => [],
          listState: AsyncError(StateError('offline'), StackTrace.empty),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.cloud_off_rounded), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
