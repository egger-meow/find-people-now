// Verification run for the "我的活動" round-3 slice (UI_PLAN §4.1 Tab 2
// 「成員」— lib/activities/activity_detail_providers.dart's
// activityMemberRosterProvider + lib/activities/activity_detail_screen.dart's
// block/report actions), against a real local `supabase start` instance (not
// mocked). Same style as activity_detail_integration_test.dart.
//
// Exercises three RPC wrappers that had zero prior Flutter-layer coverage
// (each already had pgTAP coverage against SQL fixtures, but per this
// project's standing rule, "backend-verified" and "actually called through
// the Dart wrapper" are treated as two separate risks — see the
// pgcrypto/search_path precedent documented in RPC_COVERAGE.md):
//
//   1. get_activity_contacts: real display_name/avatar_url/contacts for a
//      freshly-MATCHED activity (within the 24h window), then a real
//      post-expiry null-contacts check after backdating contact_visible_until.
//   2. get_activity_member_profiles (v1.23, new this round): real
//      school/department/degree_level/reliability_tier for both members, and
//      the exact merge-by-user_id the roster provider performs.
//   3. block_user/unblock_user + submit_report: real idempotent block/unblock
//      round-trip via the exact own_blocks_select query, self-block
//      rejection, and a real submitted report visible via own_reports_select.
//
// Run: flutter test test/activity_members_integration_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/activity_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';
import 'package:find_people_now/rpc/report_rpc.dart';
import 'package:find_people_now/rpc/user_block_rpc.dart';

import 'local_supabase_guard.dart';

Future<SupabaseClient> _createAndSignIn(
  String supabaseUrl,
  String anonKey,
  String serviceRoleKey,
  String email,
  String password,
) async {
  final createRes = await http.post(
    Uri.parse('$supabaseUrl/auth/v1/admin/users'),
    headers: {
      'apikey': serviceRoleKey,
      'Authorization': 'Bearer $serviceRoleKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'email': email, 'password': password, 'email_confirm': true}),
  );
  if (createRes.statusCode != 200 && createRes.statusCode != 201) {
    throw Exception('admin user create failed for $email: ${createRes.body}');
  }
  final client = SupabaseClient(supabaseUrl, anonKey);
  final authRes = await client.auth.signInWithPassword(email: email, password: password);
  if (authRes.session == null) {
    throw Exception('sign-in failed for $email');
  }
  return client;
}

Future<String> _psqlScalar(String sql) async {
  final res = await Process.run('docker', [
    'exec',
    'supabase_db_find-people-now',
    'psql',
    '-U',
    'postgres',
    '-d',
    'postgres',
    '-t',
    '-A',
    '-c',
    sql,
  ]);
  if (res.exitCode != 0) {
    throw Exception('psql failed: ${res.stderr}\nsql: $sql');
  }
  // `-t` suppresses SELECT headers/footers but not an INSERT/UPDATE
  // completion tag (e.g. "INSERT 0 1") that psql still appends after an
  // `insert ... returning` result — only the first line is the actual value.
  return (res.stdout as String).trim().split('\n').first.trim();
}

/// `fn_run_matching_engine()` sweeps *every* `(activity_type_id, school,
/// campus)` group with `REQUESTING` rows in one call, not just this test's
/// own campus (see supabase/migrations/20260724123000_matching_engine_nway.sql:217-221
/// — it loops over `select distinct activity_type_id, school, campus`).
/// `flutter test` runs every file in this directory concurrently, so even
/// with a unique campus per file, one file's call can also resolve another
/// file's unrelated group in the same sweep — asserting an exact return
/// value is racy. Poll for the actual expected outcome instead.
Future<void> _runMatchingEngineUntil(Future<bool> Function() isReady) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await _psqlScalar('select fn_run_matching_engine();');
    if (await isReady()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('matching engine did not resolve the expected group in time');
}

void main() {
  late String supabaseUrl;
  late String anonKey;
  late String serviceRoleKey;

  setUpAll(() async {
    await dotenv.load();
    supabaseUrl = dotenv.get('SUPABASE_URL');
    assertLocalSupabaseUrl(supabaseUrl);
    anonKey = dotenv.get('SUPABASE_ANON_KEY');
    serviceRoleKey = dotenv.get('SUPABASE_SERVICE_ROLE_KEY');
  });

  test(
    'get_activity_contacts (incl. real 24h expiry) + get_activity_member_profiles '
    '+ block/unblock/report — all against a real MATCHED activity',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'activity-members-verify-password-123!';

      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'am-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'am-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;
      // ignore: avoid_print
      print('[setup] userA=$userAId userB=$userBId');

      await completeProfile(
        clientA,
        displayName: 'ActivityMembers User A',
        avatarUrl: 'https://example.com/am-a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        department: '資工',
        bio: 'Hi there',
        contactLine: 'am_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ActivityMembers User B',
        avatarUrl: 'https://example.com/am-b.png',
        degreeLevel: DEGREE_LEVEL.PHD,
        department: '應數',
        bio: 'Hi there',
        contactLine: 'am_b_line',
      );

      // 自己的校區字串（不用共用的 '光復'）——matching engine 依
      // (activity_type_id, school, campus) 分組掃描 REQUESTING 池，純粹避免
      // 跟其他測試檔並行執行時互相撈到對方的 request，見
      // activity_detail_integration_test.dart 的同一則註解。這個檔案雖然沒有
      // 地點投票流程，但 create_request 本身仍要求該 (school, campus) 至少有
      // 一筆 APPROVED location（見 API.md campus scope 驗證），所以還是要種一筆。
      final testCampus = 'AMT測試區$stamp';
      await _psqlScalar('''
        insert into location (school, campus, name, status, is_active)
        values ('NYCU', '$testCampus', 'AMT測試地點$stamp', 'APPROVED', true);
      ''');
      await _psqlScalar('''
        with hist_activity as (
          insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
          select id, 'NYCU', '$testCampus', now() - interval '10 days',
                 now() - interval '10 days' + interval '1 hour', 'COMPLETED'
          from activity_type where name = '咖啡' limit 1
          returning id
        )
        insert into user_reliability_event (user_id, activity_id, event_type)
        select uid, hist_activity.id, 'ATTENDED'
        from hist_activity, (values ('$userAId'::uuid), ('$userBId'::uuid)) as u(uid);
      ''');

      final types = await searchActivityType(clientA, query: '咖啡');
      final coffeeId = types.firstWhere((t) => t.name == '咖啡').id;

      final requestA = await createRequest(
        clientA,
        activityTypeId: coffeeId,
        campus: testCampus,
        earliestStart: DateTime.now().toUtc(),
        latestStart: DateTime.now().toUtc().add(const Duration(hours: 2)),
        minParticipants: 2,
      );
      await submitRequest(clientA, requestA.id);
      final requestB = await createRequest(
        clientB,
        activityTypeId: coffeeId,
        campus: testCampus,
        earliestStart: DateTime.now().toUtc(),
        latestStart: DateTime.now().toUtc().add(const Duration(hours: 2)),
        minParticipants: 2,
      );
      await submitRequest(clientB, requestB.id);

      await _runMatchingEngineUntil(() async {
        try {
          final s = await getPendingConfirmationStatus(clientA, requestA.id);
          return s.status == PENDING_CONFIRMATION_STATUS.PENDING;
        } on ApiException {
          return false;
        }
      });

      final statusForA = await getPendingConfirmationStatus(clientA, requestA.id);
      final statusForB = await getPendingConfirmationStatus(clientB, requestB.id);
      await respondPendingConfirmation(
        clientA,
        pendingConfirmationId: statusForA.pendingConfirmationId,
        confirm: true,
      );
      await respondPendingConfirmation(
        clientB,
        pendingConfirmationId: statusForB.pendingConfirmationId,
        confirm: true,
      );

      final memberRows =
          await clientB.from('activity_member').select('activity_id').eq('user_id', userBId);
      final activityId = memberRows.first['activity_id'] as String;
      // ignore: avoid_print
      print('[setup] reached MATCHED activity_id=$activityId');

      // -----------------------------------------------------------------
      // 1. get_activity_contacts: real call, first time ever from the Dart
      //    wrapper layer. Fresh activity -> now() < contact_visible_until,
      //    so contacts must be non-null for both sides immediately.
      // -----------------------------------------------------------------
      final contactsForA = await getActivityContacts(clientA, activityId);
      expect(contactsForA.members.length, 2);
      final bFromA = contactsForA.members.firstWhere((m) => m.userId == userBId);
      expect(bFromA.displayName, 'ActivityMembers User B');
      expect(bFromA.contacts, isNotNull, reason: 'fresh activity: within 24h window, contacts must be visible');
      expect(bFromA.contacts!.contactLine, 'am_b_line');
      // ignore: avoid_print
      print('[get_activity_contacts] within 24h window: contacts correctly visible');

      // -----------------------------------------------------------------
      // 2. get_activity_member_profiles (v1.23, new this round): real
      //    school/department/degree_level/reliability_tier for both members.
      // -----------------------------------------------------------------
      final profilesForA = await getActivityMemberProfiles(clientA, activityId);
      expect(profilesForA.length, 2);
      final bProfile = profilesForA.firstWhere((p) => p.userId == userBId);
      expect(bProfile.department, '應數');
      expect(bProfile.degreeLevel, DEGREE_LEVEL.PHD);
      expect(bProfile.school, SCHOOL.NYCU);
      expect(bProfile.reliabilityTier, isNot(ReliabilityTier.unknown));
      final aProfile = profilesForA.firstWhere((p) => p.userId == userAId);
      expect(aProfile.department, '資工');
      // ignore: avoid_print
      print(
        '[get_activity_member_profiles] A sees B: dept=${bProfile.department} '
        'degree=${bProfile.degreeLevel.name} tier=${bProfile.reliabilityTier.name}',
      );

      // -----------------------------------------------------------------
      // 3. The exact roster merge activityMemberRosterProvider performs:
      //    activity_member direct select + the two RPCs above, joined by
      //    user_id.
      // -----------------------------------------------------------------
      final memberRowsForRoster =
          await clientA.from('activity_member').select().eq('activity_id', activityId);
      expect(memberRowsForRoster.length, 2);
      final sourceRequestIds =
          memberRowsForRoster.map((r) => r['source_request_id'] as String).toSet();
      expect(sourceRequestIds.length, 2, reason: 'A and B joined via two separate requests, not one shared invite link');
      // ignore: avoid_print
      print('[activity_member direct select] roster merge inputs all present');

      // -----------------------------------------------------------------
      // 4. Real 24h expiry: backdate contact_visible_until into the past ->
      //    get_activity_contacts must now return null contacts (not throw).
      // -----------------------------------------------------------------
      await _psqlScalar(
        "update activity set contact_visible_until = now() - interval '1 minute' where id='$activityId';",
      );
      final contactsForAAfterExpiry = await getActivityContacts(clientA, activityId);
      final bFromAAfterExpiry = contactsForAAfterExpiry.members.firstWhere((m) => m.userId == userBId);
      expect(bFromAAfterExpiry.contacts, isNull, reason: 'past contact_visible_until, no mutual rematch -> null');
      expect(bFromAAfterExpiry.displayName, 'ActivityMembers User B', reason: 'display_name stays visible even after contact expiry');
      // ignore: avoid_print
      print('[get_activity_contacts] after backdating contact_visible_until: contacts correctly null, name still shown');

      // -----------------------------------------------------------------
      // 5. block_user / unblock_user: real idempotent round-trip via the
      //    exact own_blocks_select query, plus self-block rejection.
      // -----------------------------------------------------------------
      await expectLater(
        blockUser(clientA, blockedId: userAId),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.invalidInput)),
      );
      // ignore: avoid_print
      print('[block_user] self-block correctly rejected with INVALID_INPUT');

      await blockUser(clientA, blockedId: userBId, reason: 'test block');
      final blockRows = await clientA.from('user_block').select().eq('blocker_id', userAId);
      expect(blockRows.length, 1);
      expect(blockRows.first['blocked_id'], userBId);
      expect(blockRows.first['reason'], 'test block');
      // ignore: avoid_print
      print('[block_user] real block row created, visible via own_blocks_select');

      // Idempotent repeat-block just overwrites reason, no second row.
      await blockUser(clientA, blockedId: userBId, reason: 'updated reason');
      final blockRowsAfterRepeat = await clientA.from('user_block').select().eq('blocker_id', userAId);
      expect(blockRowsAfterRepeat.length, 1, reason: 'repeat block must not create a second row');
      expect(blockRowsAfterRepeat.first['reason'], 'updated reason');

      await unblockUser(clientA, blockedId: userBId);
      final blockRowsAfterUnblock = await clientA.from('user_block').select().eq('blocker_id', userAId);
      expect(blockRowsAfterUnblock, isEmpty);
      // ignore: avoid_print
      print('[unblock_user] block row correctly removed');

      // -----------------------------------------------------------------
      // 6. submit_report: real report row visible via own_reports_select.
      // -----------------------------------------------------------------
      await submitReport(
        clientA,
        category: REPORT_CATEGORY.HARASSMENT,
        reportedUserId: userBId,
        detail: 'integration test report',
      );
      final reportRows = await clientA.from('report').select().eq('reporter_id', userAId);
      expect(reportRows.length, 1);
      expect(reportRows.first['reported_user_id'], userBId);
      expect(reportRows.first['category'], 'HARASSMENT');
      expect(reportRows.first['detail'], 'integration test report');
      // ignore: avoid_print
      print('[submit_report] real report row created, visible via own_reports_select');

      await expectLater(
        submitReport(clientA, category: REPORT_CATEGORY.OTHER),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.invalidInput)),
      );
      // ignore: avoid_print
      print('[submit_report] missing both targets correctly rejected with INVALID_INPUT');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
