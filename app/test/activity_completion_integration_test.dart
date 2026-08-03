// Verification run for the "我的活動" round-4 slice (UI_PLAN.md §6.3
// 完成確認＋再約 — lib/activities/activity_detail_providers.dart's
// ownCompletionReportProvider/ownRematchVotesProvider +
// activity_detail_screen.dart's _CompletionReportSheet/_RematchSheet/
// _RematchButton), against a real local `supabase start` instance (not
// mocked). Same style as activity_detail_integration_test.dart /
// activity_members_integration_test.dart.
//
// submit_completion_report and rematch_vote are NOT new RPCs (Phase 7,
// already pgTAP-covered — see 11_complete_and_remind_activities.test.sql and
// 14_activity_validation_gaps.test.sql) and lib/rpc/completion_rpc.dart
// already existed before this round. But per this project's standing rule,
// "backend-verified" and "actually called through the Dart wrapper from a
// real client" are two separate risks — this file is the first time either
// wrapper function has ever been exercised against a real running instance.
//
// Exercises, all for real:
//   1. INVALID_ABSENT_TARGET: absentUserIds pointing at a non-member.
//   2. submit_completion_report settlement math for a 2-person activity
//      (quorum = ceil(2/2) = 1, so the FIRST report alone settles it):
//      REPORTED_ABSENT against the other member -> real NO_SHOW event for
//      the accused, real ATTENDED event for the reporter, activity flips to
//      COMPLETED in the same call.
//   3. ACTIVITY_NOT_ENDED: a second member trying to report after the
//      activity already auto-settled to COMPLETED.
//   4. rematch_vote: CANNOT_VOTE_SELF, NOT_ACTIVITY_MEMBER against a
//      stranger, one-sided vote (is_mutual=false) then the reverse vote
//      completing it (is_mutual=true).
//   5. The exact RLS-scoped queries ownCompletionReportProvider /
//      ownRematchVotesProvider issue (own_reports_select / own_votes_select
//      — non-attribution, see SPEC §12.1.2).
//
// Run: flutter test test/activity_completion_integration_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/completion_report.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/completion_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';

const _strangerId = '00000000-0000-0000-0000-000000000000';

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
/// own campus (see supabase/migrations/20260724123000_matching_engine_nway.sql:217-221).
/// `flutter test` runs every file in this directory concurrently, so even
/// with a unique campus per file, asserting an exact return value is racy —
/// poll for the actual expected outcome instead.
Future<void> _runMatchingEngineUntil(Future<bool> Function() isReady) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await _psqlScalar('select fn_run_matching_engine();');
    if (await isReady()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('matching engine did not resolve the expected group in time');
}

/// The exact query [ownCompletionReportProvider] issues.
Future<CompletionReport?> _ownCompletionReportQuery(SupabaseClient client, String activityId) async {
  final rows = await client.from('completion_report').select().eq('activity_id', activityId);
  return rows.isEmpty ? null : CompletionReport.fromJson(rows.first);
}

/// The exact query [ownRematchVotesProvider] issues.
Future<Set<String>> _ownRematchVotesQuery(SupabaseClient client, String activityId) async {
  final rows = await client.from('rematch_vote').select().eq('activity_id', activityId);
  return rows.map((r) => r['to_user_id'] as String).toSet();
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
    'submit_completion_report settlement (NO_SHOW/ATTENDED, ACTIVITY_NOT_ENDED '
    'after auto-settle) + rematch_vote (self/stranger rejection, one-sided then '
    'mutual) — all against a real ONGOING activity',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'activity-completion-verify-password-123!';

      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ac-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ac-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;
      // ignore: avoid_print
      print('[setup] userA=$userAId userB=$userBId');

      await completeProfile(
        clientA,
        displayName: 'ActivityCompletion User A',
        avatarUrl: 'https://example.com/ac-a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ac_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ActivityCompletion User B',
        avatarUrl: 'https://example.com/ac-b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ac_b_line',
      );

      // 自己的校區字串，理由同其他三個檔案：matching engine 系統級掃描
      // REQUESTING 池，避免跟平行執行的其他測試檔互相撈到對方的 request。
      final testCampus = 'ACT測試區$stamp';
      await _psqlScalar('''
        insert into location (school, campus, name, status, is_active)
        values ('NYCU', '$testCampus', 'ACT測試地點$stamp', 'APPROVED', true);
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

      // Reach ONGOING: fn_start_activities() flips status regardless of
      // whether a location got locked (zero-candidate case leaves
      // activity_location_id NULL, per supabase/migrations/20260724121500_campus_scope_rpc.sql:557-558)
      // — completion reporting doesn't depend on the location tab at all.
      await _psqlScalar(
        "update activity set start_time = now() - interval '1 minute' where id='$activityId';",
      );
      var ongoing = false;
      for (var attempt = 0; attempt < 10 && !ongoing; attempt++) {
        await _psqlScalar('select fn_start_activities();');
        final row = await clientA.from('activity').select().eq('id', activityId).single();
        ongoing = row['status'] == 'ONGOING';
        if (!ongoing) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(ongoing, isTrue, reason: 'fn_start_activities did not flip the activity to ONGOING in time');
      // ignore: avoid_print
      print('[setup] activity is ONGOING');

      // -----------------------------------------------------------------
      // 0. Before either party reports: ownCompletionReportProvider's query
      //    must see nothing yet (own_reports_select RLS).
      // -----------------------------------------------------------------
      expect(await _ownCompletionReportQuery(clientA, activityId), isNull);

      // -----------------------------------------------------------------
      // 1. INVALID_ABSENT_TARGET: absentUserIds must be limited to real
      //    JOINED members. This must raise BEFORE inserting a row (verified
      //    next by asserting the settlement in step 2 still uses report
      //    count 1, not 2).
      // -----------------------------------------------------------------
      await expectLater(
        submitCompletionReport(
          clientA,
          activityId: activityId,
          result: COMPLETION_RESULT.REPORTED_ABSENT,
          absentUserIds: [_strangerId],
        ),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.invalidAbsentTarget)),
      );
      // ignore: avoid_print
      print('[submit_completion_report] non-member absent target correctly rejected with INVALID_ABSENT_TARGET');

      // -----------------------------------------------------------------
      // 2. Real settlement: 2-person activity -> quorum = ceil(2/2) = 1, so
      //    A's single REPORTED_ABSENT report against B settles it
      //    immediately in the same call: NO_SHOW for B, ATTENDED for A,
      //    activity flips to COMPLETED.
      // -----------------------------------------------------------------
      final reportResult = await submitCompletionReport(
        clientA,
        activityId: activityId,
        result: COMPLETION_RESULT.REPORTED_ABSENT,
        absentUserIds: [userBId],
      );
      expect(reportResult.success, isTrue);
      expect(reportResult.settled, isTrue, reason: 'quorum=1 for a 2-person activity, so the first report settles it');

      final ownReport = await _ownCompletionReportQuery(clientA, activityId);
      expect(ownReport, isNotNull);
      expect(ownReport!.result, COMPLETION_RESULT.REPORTED_ABSENT);
      expect(ownReport.absentUserIds, [userBId]);
      // ignore: avoid_print
      print('[completion_report own_reports_select] A\'s own report correctly visible: ${ownReport.result.name}');

      final activityAfter = await clientA.from('activity').select().eq('id', activityId).single();
      expect(activityAfter['status'], 'COMPLETED');
      // ignore: avoid_print
      print('[activity] settled to COMPLETED by the single report');

      final aEvents = await clientA
          .from('user_reliability_event')
          .select()
          .eq('activity_id', activityId)
          .eq('user_id', userAId);
      expect(aEvents.length, 1);
      expect(aEvents.first['event_type'], 'ATTENDED', reason: 'reporter, not marked absent by anyone');

      final bEvents = await clientB
          .from('user_reliability_event')
          .select()
          .eq('activity_id', activityId)
          .eq('user_id', userBId);
      expect(bEvents.length, 1);
      expect(bEvents.first['event_type'], 'NO_SHOW', reason: 'marked absent by A, no-show count (1) met quorum (1)');
      // ignore: avoid_print
      print('[user_reliability_event own_reliability_select] A=ATTENDED, B=NO_SHOW — both correctly self-visible');

      // -----------------------------------------------------------------
      // 3. ACTIVITY_NOT_ENDED: B tries to report after the activity has
      //    already auto-settled to COMPLETED.
      // -----------------------------------------------------------------
      await expectLater(
        submitCompletionReport(clientB, activityId: activityId, result: COMPLETION_RESULT.WENT_WELL),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.activityNotEnded)),
      );
      // ignore: avoid_print
      print('[submit_completion_report] report after auto-settlement correctly rejected with ACTIVITY_NOT_ENDED');

      // -----------------------------------------------------------------
      // 4. rematch_vote: self-vote, stranger target, one-sided then mutual.
      // -----------------------------------------------------------------
      await expectLater(
        rematchVote(clientA, activityId: activityId, toUserId: userAId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.invalidInput)
              .having((e) => e.detail, 'detail', 'CANNOT_VOTE_SELF'),
        ),
      );
      // ignore: avoid_print
      print('[rematch_vote] self-vote correctly rejected with INVALID_INPUT/CANNOT_VOTE_SELF');

      await expectLater(
        rematchVote(clientA, activityId: activityId, toUserId: _strangerId),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.notActivityMember)),
      );
      // ignore: avoid_print
      print('[rematch_vote] stranger target correctly rejected with NOT_ACTIVITY_MEMBER');

      final oneSided = await rematchVote(clientA, activityId: activityId, toUserId: userBId);
      expect(oneSided.success, isTrue);
      expect(oneSided.isMutual, isFalse, reason: 'B has not voted for A yet');

      final aVotes = await _ownRematchVotesQuery(clientA, activityId);
      expect(aVotes, {userBId});
      final bVotesBeforeReciprocation = await _ownRematchVotesQuery(clientB, activityId);
      expect(bVotesBeforeReciprocation, isEmpty, reason: "own_votes_select must not leak A's vote onto B's query");
      // ignore: avoid_print
      print('[rematch_vote own_votes_select] one-sided vote correctly isolated per RLS (A sees it, B does not)');

      final mutual = await rematchVote(clientB, activityId: activityId, toUserId: userAId);
      expect(mutual.success, isTrue);
      expect(mutual.isMutual, isTrue, reason: 'both directions now recorded');

      final bVotesAfterReciprocation = await _ownRematchVotesQuery(clientB, activityId);
      expect(bVotesAfterReciprocation, {userAId});
      // ignore: avoid_print
      print('[rematch_vote] reverse vote correctly reports is_mutual=true');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
