// Verification run for the "我的活動" round-1 frontend slice, against a real
// local `supabase start` instance (not mocked) — same style as
// test/rpc_smoke_test.dart / test/activity_location_voting_smoke_test.dart.
//
// Drives the exact queries lib/activities/my_activities_providers.dart issues
// (not through widgets — this repo's existing convention for RPC/Realtime
// integration tests) plus the brand-new
// get_pending_confirmation_candidate_info RPC (docs/API.md §4.3, added this
// round to back SPEC.md §12.1.3's "安全資訊卡", which never had a data source
// before — see SPEC.md's v1.22 changelog entry):
//
//   1. Two real users reach PENDING_CONFIRMATION (same real 2-person path
//      activity_location_voting_smoke_test.dart already exercises) ->
//      get_pending_confirmation_candidate_info returns the *other* party's
//      profile, symmetrically, matching what myMatchRequestsProvider's
//      REQUESTING-stage query would have shown before the merge.
//   2. Both confirm -> the exact `activity_member` embed query
//      myActivitiesFromActivityTableProvider issues picks up the new
//      Activity for both users, and the exact `match_request` status-filtered
//      query myMatchRequestsProvider issues no longer includes the now-MATCHED
//      request (superseded by the Activity row, not duplicated in the list).
//   3. A separately cancelled request shows up via that same status-filtered
//      query in the CANCELLED bucket.
//
// Run: flutter test test/my_activities_integration_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';

const _myRequestListStatuses = ['REQUESTING', 'PENDING_CONFIRMATION', 'EXPIRED', 'CANCELLED'];

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

/// `docker exec ... psql -t -A -c "<sql>"` — same escape hatch
/// activity_location_voting_smoke_test.dart already uses, for the one thing
/// no client RPC can do: triggering the pg_cron-only matching engine.
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
/// campus)` group with `REQUESTING` rows in one call, not just the group
/// this test cares about (see supabase/migrations/20260724123000_matching_engine_nway.sql:217-221
/// — it loops over `select distinct activity_type_id, school, campus`).
/// `flutter test` runs every file in this directory concurrently by
/// default, so when multiple integration test files each have a matchable
/// pair sitting in `match_request` at the same moment, one file's call can
/// resolve another file's group (and vice versa) — asserting an exact
/// `fn_run_matching_engine()` return value is inherently racy. Poll for the
/// actual expected outcome instead, retrying the engine call if a
/// concurrently-running file's call raced ahead of this one.
Future<void> _runMatchingEngineUntil(Future<bool> Function() isReady) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await _psqlScalar('select fn_run_matching_engine();');
    if (await isReady()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('matching engine did not resolve the expected group in time');
}

/// The exact query `myMatchRequestsProvider` issues (lib/activities/
/// my_activities_providers.dart) — deliberately no `.eq('owner_id', ...)`,
/// relying purely on RLS (`my_requests_select`: owner OR request_member) to
/// scope to "my" requests, same as the manual `set local role authenticated`
/// probe run before writing that provider.
Future<List<MatchRequest>> _myRequestListQuery(SupabaseClient client) async {
  final rows =
      await client.from('match_request').select().inFilter('status', _myRequestListStatuses);
  return rows.map(MatchRequest.fromJson).toList();
}

/// The exact query `myActivitiesFromActivityTableProvider` issues.
Future<List<Activity>> _myActivityListQuery(SupabaseClient client, String userId) async {
  final rows =
      await client.from('activity_member').select('activity:activity_id(*)').eq('user_id', userId);
  return rows
      .map((r) => r['activity'])
      .whereType<Map<String, dynamic>>()
      .map(Activity.fromJson)
      .toList();
}

void main() {
  late String supabaseUrl;
  late String anonKey;
  late String serviceRoleKey;

  setUpAll(() async {
    await dotenv.load();
    supabaseUrl = dotenv.get('SUPABASE_URL');
    anonKey = dotenv.get('SUPABASE_ANON_KEY');
    serviceRoleKey = dotenv.get('SUPABASE_SERVICE_ROLE_KEY');
  });

  test(
    'REQUESTING -> PENDING_CONFIRMATION (candidate info RPC, symmetric) -> MATCHED '
    'all surface correctly through the exact queries the my-activities providers issue',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'my-activities-verify-password-123!';

      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ma-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ma-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;
      // ignore: avoid_print
      print('[setup] userA=$userAId userB=$userBId');

      await completeProfile(
        clientA,
        displayName: 'MyActivities User A',
        avatarUrl: 'https://example.com/ma-a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        department: '資工',
        contactLine: 'ma_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'MyActivities User B',
        avatarUrl: 'https://example.com/ma-b.png',
        degreeLevel: DEGREE_LEVEL.PHD,
        department: '應數',
        contactLine: 'ma_b_line',
      );

      // 自己的校區字串（不用共用的 '光復'）——matching engine 依
      // (activity_type_id, school, campus) 分組掃描 REQUESTING 池，這個測試會
      // 在送出 REQUESTING 後、呼叫 matching engine 前檢查「還是 REQUESTING」，
      // 若跟其他測試檔共用同一組，對方的 engine 呼叫可能搶先把這裡的 request
      // 撈走合併，造成這個檢查點就已經變成 PENDING_CONFIRMATION（曾實際觀察到
      // 這個 race，不是純理論風險）。這裡不需要真的 location（沒有地點投票
      // 流程），但 create_request 仍要求該 (school, campus) 至少有一筆
      // APPROVED location，所以還是要種一筆。
      final testCampus = 'MAT測試區$stamp';
      await _psqlScalar('''
        insert into location (school, campus, name, status, is_active)
        values ('NYCU', '$testCampus', 'MAT測試地點$stamp', 'APPROVED', true);
      ''');

      // Both are brand-new users with zero ATTENDED history, so
      // min_participants=2 would trip NEW_USER_LOW_HEADCOUNT at submit_request
      // — seed one historical ATTENDED event each first, same fixture escape
      // hatch activity_location_voting_smoke_test.dart uses.
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
      // ignore: avoid_print
      print('[submit_request] A=${requestA.id} B=${requestB.id}, both REQUESTING');

      // -----------------------------------------------------------------
      // 1. Before matching: the exact my-activities list query sees each
      //    request as REQUESTING, from each owner's own perspective.
      // -----------------------------------------------------------------
      final listABefore = await _myRequestListQuery(clientA);
      expect(
        listABefore.where((r) => r.id == requestA.id).single.status,
        REQUEST_STATUS.REQUESTING,
      );
      final listBBefore = await _myRequestListQuery(clientB);
      expect(
        listBBefore.where((r) => r.id == requestB.id).single.status,
        REQUEST_STATUS.REQUESTING,
      );
      // ignore: avoid_print
      print('[my_activities list] both requests correctly show REQUESTING pre-match');

      // -----------------------------------------------------------------
      // 2. Trigger the matching engine -> merges to exactly 2 people ->
      //    PENDING_CONFIRMATION (same real 2-person path
      //    activity_location_voting_smoke_test.dart already covers).
      // -----------------------------------------------------------------
      await _runMatchingEngineUntil(() async {
        try {
          final s = await getPendingConfirmationStatus(clientA, requestA.id);
          return s.status == PENDING_CONFIRMATION_STATUS.PENDING;
        } on ApiException {
          return false;
        }
      });

      final statusForA = await getPendingConfirmationStatus(clientA, requestA.id);
      expect(statusForA.status, PENDING_CONFIRMATION_STATUS.PENDING);
      final statusForB = await getPendingConfirmationStatus(clientB, requestB.id);
      expect(statusForB.pendingConfirmationId, statusForA.pendingConfirmationId);
      // ignore: avoid_print
      print('[fn_run_matching_engine] PENDING_CONFIRMATION id=${statusForA.pendingConfirmationId}');

      // The my-activities list query should now show PENDING_CONFIRMATION
      // for both, which is what routes to PendingConfirmationCard in the UI.
      final listAPending = await _myRequestListQuery(clientA);
      expect(
        listAPending.where((r) => r.id == requestA.id).single.status,
        REQUEST_STATUS.PENDING_CONFIRMATION,
      );

      // -----------------------------------------------------------------
      // 3. get_pending_confirmation_candidate_info (v1.22, new this round) —
      //    the real backing data source for SPEC §12.1.3's "安全資訊卡",
      //    which had none before. Verify symmetric: A sees B's profile
      //    (not A's own), and vice versa, with the exact department/degree
      //    values set via complete_profile above — not stub/placeholder
      //    data.
      // -----------------------------------------------------------------
      final candidateForA = await getPendingConfirmationCandidateInfo(
        clientA,
        statusForA.pendingConfirmationId,
      );
      expect(candidateForA.displayName, 'MyActivities User B');
      expect(candidateForA.department, '應數');
      expect(candidateForA.degreeLevel, DEGREE_LEVEL.PHD);
      expect(candidateForA.school, SCHOOL.NYCU);
      expect(candidateForA.completedActivityCount, 1, reason: 'B has exactly the one seeded ATTENDED event');

      final candidateForB = await getPendingConfirmationCandidateInfo(
        clientB,
        statusForB.pendingConfirmationId,
      );
      expect(candidateForB.displayName, 'MyActivities User A');
      expect(candidateForB.department, '資工');
      expect(candidateForB.degreeLevel, DEGREE_LEVEL.MASTER);
      // ignore: avoid_print
      print(
        '[get_pending_confirmation_candidate_info] symmetric: A sees "${candidateForA.displayName}", '
        'B sees "${candidateForB.displayName}"',
      );

      // A stranger (a third real user, no relation to this pending
      // confirmation) must be rejected with FORBIDDEN — not just "trust the
      // migration", actually call it as a real unrelated authenticated user.
      final clientStranger = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ma-stranger-$stamp@nycu.edu.tw',
        password,
      );
      await completeProfile(
        clientStranger,
        displayName: 'MyActivities Stranger',
        avatarUrl: 'https://example.com/ma-stranger.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        contactLine: 'ma_stranger_line',
      );
      await expectLater(
        getPendingConfirmationCandidateInfo(clientStranger, statusForA.pendingConfirmationId),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.forbidden)),
      );
      // ignore: avoid_print
      print('[get_pending_confirmation_candidate_info] stranger call correctly rejected');

      // -----------------------------------------------------------------
      // 4. Both confirm -> Activity created. The exact
      //    myActivitiesFromActivityTableProvider query now picks it up for
      //    both users, and the request-status query no longer lists the
      //    (now MATCHED) request — it's superseded by the Activity, not
      //    duplicated.
      // -----------------------------------------------------------------
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

      final myActivitiesA = await _myActivityListQuery(clientA, userAId);
      expect(myActivitiesA, isNotEmpty);
      expect(myActivitiesA.first.status, ACTIVITY_STATUS.MATCHED);
      final myActivitiesB = await _myActivityListQuery(clientB, userBId);
      expect(myActivitiesB.map((a) => a.id), contains(myActivitiesA.first.id));
      // ignore: avoid_print
      print('[activity_member embed query] both A and B now see activity ${myActivitiesA.first.id}');

      final listAAfterMatch = await _myRequestListQuery(clientA);
      expect(
        listAAfterMatch.where((r) => r.id == requestA.id),
        isEmpty,
        reason: 'MATCHED requests are superseded by the Activity row, not shown twice',
      );
      // ignore: avoid_print
      print('[my_activities list] MATCHED request correctly excluded (represented by Activity instead)');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'a cancelled request shows up in the CANCELLED bucket via the exact my-activities list query',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'my-activities-cancel-password-123!';

      final client = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ma-cancel-$stamp@nycu.edu.tw',
        password,
      );

      await completeProfile(
        client,
        displayName: 'MyActivities Cancel User',
        avatarUrl: 'https://example.com/ma-cancel.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        contactLine: 'ma_cancel_line',
      );

      final types = await searchActivityType(client, query: '咖啡');
      final coffeeId = types.firstWhere((t) => t.name == '咖啡').id;

      final request = await createRequest(
        client,
        activityTypeId: coffeeId,
        campus: '光復',
        earliestStart: DateTime.now().toUtc(),
        latestStart: DateTime.now().toUtc().add(const Duration(hours: 2)),
        minParticipants: 3,
      );
      await submitRequest(client, request.id);
      final cancelled = await cancelRequest(client, request.id);
      expect(cancelled.status, REQUEST_STATUS.CANCELLED);

      final list = await _myRequestListQuery(client);
      expect(list.where((r) => r.id == request.id).single.status, REQUEST_STATUS.CANCELLED);
      // ignore: avoid_print
      print('[my_activities list] cancelled request correctly surfaces with CANCELLED status');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
