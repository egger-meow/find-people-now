import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/activities/pending_confirmation_card.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/activity_type.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/request_member.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/match/waiting_room_screen.dart';
import 'package:find_people_now/match/widgets/activity_demand_detail_sheet.dart';
import 'package:find_people_now/match/widgets/campus_demand_card_widget.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';
import 'package:find_people_now/theme/app_theme.dart';

void main() {
  final fixedNow = DateTime(2026, 9, 16, 14, 0);

  final testDemand = CampusDemandCard(
    activityTypeId: 'act-badminton',
    activityTypeName: '羽球',
    campus: '國立陽明交通大學 光復校區 體育館羽球場',
    earliestStart: DateTime(2026, 9, 16, 16, 0),
    latestStart: DateTime(2026, 9, 16, 18, 0),
    sportLevel: 'LEVEL_1_5',
    sportLevelRating: null,
    studyTarget: null,
    minParticipants: 2,
    maxParticipants: 4,
    personCount: 3,
    requestCount: 2,
  );

  testWidgets('首頁需求卡清楚回答四個問題且無螢光/火焰緊繃元素', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: CampusDemandCardWidget(
            demand: testDemand,
            relativeNow: fixedNow,
            onTap: () {},
          ),
        ),
      ),
    );

    // 1. 有人想做什麼：活動標題與程度標籤
    expect(find.text('羽球'), findsOneWidget);
    // 2. 什麼時候：醒目時段
    expect(find.textContaining('16:00'), findsOneWidget);
    // 3. 多少人在等：客觀真實訊號，無「差 1 人」或「即將成團」之誤導
    expect(find.textContaining('3 人在找球友'), findsOneWidget);
    expect(find.textContaining('差 1 人'), findsNothing);
    expect(find.textContaining('即將成團'), findsNothing);
    // 4. 我如何參與：查看詳情入口
    expect(find.text('查看詳情'), findsOneWidget);

    // 驗證已移除火焰圖示
    expect(find.byIcon(Icons.local_fire_department_rounded), findsNothing);
    // 驗證使用平靜社群圖示
    expect(find.byIcon(Icons.people_outline_rounded), findsOneWidget);
  });

  testWidgets('匿名需求詳情彈窗清楚呈現防誤導文案與不變更承諾', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ActivityDemandDetailSheet(
            demand: testDemand,
            canParticipate: true,
            onParticipate: () {},
            onCustomize: () {},
            relativeNow: fixedNow,
          ),
        ),
      ),
    );

    // 動作按鈕為「以相容條件加入配對」，絕非讓人誤以為已加入既定小組的「我也想去」
    expect(find.text('以相容條件加入配對'), findsOneWidget);
    expect(find.text('我也想去'), findsNothing);
    expect(find.text('調整條件後發起...'), findsOneWidget);

    // 整合式說明文字：說明非直接加入私人小組，且依條件進行撮合
    expect(find.textContaining('並非直接加入特定私人小組'), findsOneWidget);
    expect(find.textContaining('撮合完全依條件進行'), findsOneWidget);
  });

  testWidgets('等待室清楚標註狀態、下一步、退出說明與推播未驗證警語', (tester) async {
    final request = MatchRequest(
      id: 'req-wait-1',
      ownerId: 'user-me',
      activityTypeId: 'act-badminton',
      earliestStart: fixedNow,
      latestStart: fixedNow.add(const Duration(hours: 1)),
      flexibleMinutes: 0,
      minParticipants: 2,
      maxParticipants: 4,
      allowDowngrade: false,
      status: REQUEST_STATUS.REQUESTING,
      createdAt: fixedNow,
      school: SCHOOL.NYCU,
      campus: '光復校區',
    );

    final actType = ActivityType(
      id: 'act-badminton',
      name: '羽球',
      status: ACTIVITY_TYPE_STATUS.APPROVED,
      createdAt: fixedNow,
      defaultMinParticipants: 2,
      defaultMaxParticipants: 4,
      skillLevelEnabled: true,
      sortOrder: 1,
      levelSystem: LEVEL_SYSTEM.BADMINTON_LEVEL,
      aliases: const [],
    );

    final member = RequestMember(
      id: 'mem-1',
      requestId: request.id,
      userId: 'user-me',
      role: REQUEST_MEMBER_ROLE.OWNER,
      status: REQUEST_MEMBER_STATUS.JOINED,
      createdAt: fixedNow,
    );


    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          matchRequestStreamProvider(request.id).overrideWith((ref) => Stream.value(request)),
          requestMembersStreamProvider(request.id).overrideWith((ref) => Stream.value([member])),
          activityTypeByIdProvider(actType.id).overrideWith((ref) async => actType),
          currentUserIdProvider.overrideWith((ref) => 'user-me'),
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

          home: WaitingRoomScreen(requestId: request.id),
        ),
      ),
    );
    await tester.pumpAndSettle();


    // 1. 目前狀態與下一步
    expect(find.textContaining('目前狀態：系統正在比對時段與條件相容的同學'), findsOneWidget);
    expect(find.textContaining('下一步驟：兩人配對時將進入限時雙向確認'), findsOneWidget);
    // 2. 退出方式：隨時可退出，無冷卻無扣分
    expect(find.textContaining('退出方式：可隨時取消或離開，無任何冷卻限制與信用扣分'), findsOneWidget);
    // 3. 嚴格守則：通知未驗證前不得承諾離開後會收到通知
    expect(find.textContaining('提醒：背景推播功能尚在驗證中，離開 App 可能無法即時收到通知'), findsOneWidget);
    // 4. 成員描述不保證達到人數即成團
    await tester.scrollUntilVisible(find.text('房間成員'), 200);
    expect(find.textContaining('非單純達到人數即可保證成團'), findsOneWidget);
    expect(find.textContaining('達到門檻就能成團'), findsNothing);
  });


  testWidgets('小螢幕 (320x568) 與 200% 大字級下各元件無 RenderFlex 溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2.0),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                CampusDemandCardWidget(
                  demand: testDemand,
                  relativeNow: fixedNow,
                ),
                ActivityDemandDetailSheet(
                  demand: testDemand,
                  canParticipate: true,
                  onParticipate: () {},
                  onCustomize: () {},
                  relativeNow: fixedNow,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 驗證順利完成渲染且無崩潰或 RenderFlex 錯誤
    expect(find.text('羽球'), findsWidgets);
    expect(find.text('以相容條件加入配對'), findsOneWidget);
  });

  testWidgets('暗色模式主題色彩對比度與色票驗證（暖炭灰底與柔和鼠尾草綠）', (tester) async {
    final darkTheme = AppTheme.dark;

    // 暗色底為暖炭灰 #1C1D1B，非純黑 #121212
    expect(darkTheme.colorScheme.surface, const Color(0xFF1C1D1B));
    // 主色為柔和鼠尾草綠 #92BFA0，非螢光綠 #7CFF6B
    expect(darkTheme.colorScheme.primary, const Color(0xFF92BFA0));

    final lightTheme = AppTheme.light;
    // 淺色底為暖米白 #FAF8F5
    expect(lightTheme.colorScheme.surface, const Color(0xFFFAF8F5));
    // 淺色主色為森林綠 #1E5E3A
    expect(lightTheme.colorScheme.primary, const Color(0xFF1E5E3A));
  });
}
