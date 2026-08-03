// Verification run for the Activity Location voting RPC wrappers
// (lib/rpc/activity_rpc.dart: proposeActivityLocation/voteActivityLocation),
// against a real local `supabase start` instance (not mocked).
//
// Unlike rpc_smoke_test.dart (which deliberately stops at submit_request
// throwing NEW_USER_LOW_HEADCOUNT), this test drives two real, separately
// authenticated users all the way to a real MATCHED Activity, then exercises
// the full propose -> vote -> tally -> fn_start_activities lock flow.
//
// Getting to a real MATCHED Activity through the actual RPC surface (not a
// raw SQL fixture, like the pgTAP tests use) requires routing around one
// thing client code can't drive: `fn_run_matching_engine()` is a
// `pg_cron`-only function, no client RPC triggers it (see docs/API.md §9) —
// invoked here via `docker exec psql`, the same escape hatch
// rpc_smoke_test.dart already uses for seeding.
//
// Two solo real users merging totals exactly 2 JOINED members, which routes
// through `commit_match`'s <=2 branch -> PENDING_CONFIRMATION, requiring
// both sides to call `respond_pending_confirmation(confirm: true)` before an
// Activity exists. This used to be unusable here because that PC1 path had a
// bug (commit_match re-entry re-derived the same <=2 branch and inserted a
// duplicate pending_confirmation instead of creating the Activity — fixed in
// supabase/migrations/20260724122000_fix_commit_match_pc1.sql, covered by
// supabase/tests/database/08_pc1_activity_creation.test.sql). This test now
// exercises that real 2-person path end-to-end instead of routing around it.
//
// Run: flutter test test/activity_location_voting_smoke_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/activity_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';

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
/// rpc_smoke_test.dart already uses, for the two things no client RPC can
/// do: triggering the pg_cron-only matching engine, and seeding raw fixture
/// rows that mirror what the pgTAP tests set up directly in SQL.
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
    'two real users reach a MATCHED activity -> propose/vote a location -> '
    'tally is correct -> fn_start_activities locks it',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'flutter-verify-password-123!';

      // 1/2. Two independently authenticated users (separate SupabaseClient
      // instances — each holds its own JWT session).
      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'alv-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'alv-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;
      // ignore: avoid_print
      print('[setup] userA=$userAId userB=$userBId');

      await completeProfile(
        clientA,
        displayName: 'ALV User A',
        avatarUrl: 'https://example.com/a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'alv_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ALV User B',
        avatarUrl: 'https://example.com/b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'alv_b_line',
      );

      const testCampus = '光復';
      final locationId = await _psqlScalar(
        "select id from location where school='NYCU' and campus='$testCampus' "
        "and name='Flutter 驗證測試地點' limit 1;",
      );
      expect(locationId, isNotEmpty, reason: 'run the location seed first (see app/README.md)');
      // ignore: avoid_print
      print('[setup] candidate location id=$locationId');

      // 2.5. This test's real intent is the small-headcount path (SPEC §12.1
      // "≤2 人安全確認" + the location-voting flow that follows it), so
      // min_participants=2 (not 3 — the old min=3 only existed to dodge
      // submit_request's NEW_USER_LOW_HEADCOUNT gate, which is a workaround,
      // not the scenario being tested). With min=2, both fresh test accounts
      // WOULD trip that gate (fn_is_new_user = true for anyone with zero
      // 'ATTENDED' rows), so seed one historical ATTENDED event per user
      // first — the same raw-SQL fixture escape hatch used elsewhere in this
      // file, mirroring how the pgTAP tests attach reliability events to a
      // real (fixture) activity row rather than special-casing the gate.
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
      // ignore: avoid_print
      print('[setup] seeded ATTENDED history for userA/userB (unlocks low-headcount eligibility)');

      // 3. Both users create+submit a real REQUESTING request via the actual
      // RPC surface. min_participants=2, matching the real merge total (1+1),
      // which lands in commit_match's <=2 PENDING_CONFIRMATION branch — the
      // real 2-person path, not routed around it.
      final types = await searchActivityType(clientA, query: '咖啡');
      expect(types, isNotEmpty);
      final coffeeId = types.firstWhere((t) => t.name == '咖啡').id;

      // earliestStart is deliberately 1 hour out, not `now()`: the matching
      // engine derives the resulting Activity's start_time from
      // greatest(earliest_start, ...) across accumulated members, and
      // fn_start_activities() sweeps every MATCHED activity system-wide with
      // start_time <= now() (not scoped to this test). A `now()` earliest
      // start makes the freshly-created activity sweep-eligible the instant
      // it exists, so a concurrent test file's fn_start_activities() call can
      // flip it to ONGOING before this test gets to propose/vote a location
      // itself — breaking propose_activity_location's `status = 'MATCHED'`
      // requirement. Starting 1 hour out keeps it MATCHED until step 10
      // explicitly backdates start_time to unlock it.
      final earliestStart = DateTime.now().toUtc().add(const Duration(hours: 1));
      final latestStart = DateTime.now().toUtc().add(const Duration(hours: 3));

      final requestA = await createRequest(
        clientA,
        activityTypeId: coffeeId,
        campus: testCampus,
        earliestStart: earliestStart,
        latestStart: latestStart,
        minParticipants: 2,
      );
      await submitRequest(clientA, requestA.id);
      // ignore: avoid_print
      print('[create_request/submit_request] A -> ${requestA.id} REQUESTING');

      final requestB = await createRequest(
        clientB,
        activityTypeId: coffeeId,
        campus: testCampus,
        earliestStart: earliestStart,
        latestStart: latestStart,
        minParticipants: 2,
      );
      await submitRequest(clientB, requestB.id);
      // ignore: avoid_print
      print('[create_request/submit_request] B -> ${requestB.id} REQUESTING');

      // 4. Trigger the matching engine (pg_cron-only, no client RPC exists —
      // see docs/API.md §9). Total merged size = 1 (A) + 1 (B) = 2 <= 2, so
      // commit_match creates a pending_confirmation instead of an Activity —
      // both sides must respond_pending_confirmation(confirm: true) below.
      await _runMatchingEngineUntil(() async {
        try {
          final s = await getPendingConfirmationStatus(clientA, requestA.id);
          return s.status == PENDING_CONFIRMATION_STATUS.PENDING;
        } on ApiException {
          return false;
        }
      });

      // 5. Each side independently reads its own pending confirmation status
      // through the real RPC (not raw SQL) — mirrors how a client would
      // actually discover it needs to respond.
      final statusForA = await getPendingConfirmationStatus(clientA, requestA.id);
      expect(statusForA.status, PENDING_CONFIRMATION_STATUS.PENDING);
      final statusForB = await getPendingConfirmationStatus(clientB, requestB.id);
      expect(statusForB.status, PENDING_CONFIRMATION_STATUS.PENDING);
      expect(statusForB.pendingConfirmationId, statusForA.pendingConfirmationId);
      // ignore: avoid_print
      print('[fn_run_matching_engine] merged -> PENDING_CONFIRMATION id=${statusForA.pendingConfirmationId}');

      // 6. Both sides confirm. This is exactly the PC1 path that used to be
      // broken: commit_match's re-entry re-derived the same <=2 branch and
      // inserted a duplicate pending_confirmation instead of creating the
      // Activity (fixed in
      // supabase/migrations/20260724122000_fix_commit_match_pc1.sql).
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
      // ignore: avoid_print
      print('[respond_pending_confirmation] both A and B confirmed');

      // Live regression check of the exact bug: exactly one
      // pending_confirmation row for this pair, not two.
      final pcCount = await _psqlScalar(
        "select count(*) from pending_confirmation where id='${statusForA.pendingConfirmationId}';",
      );
      expect(pcCount, '1');

      // 7. Fetch the resulting activity via a real authenticated PostgREST
      // read (client.from(...), not raw SQL) — this is also a live
      // regression check of the activity_member RLS recursion fix (see
      // supabase/migrations/20260724121900_fix_activity_member_rls_recursion.sql):
      // this exact query 500'd unconditionally before that fix.
      final memberRows = await clientB
          .from('activity_member')
          .select('activity_id')
          .eq('user_id', userBId);
      expect(memberRows, isNotEmpty, reason: 'user B should be a member of the merged activity');
      final activityId = memberRows.first['activity_id'] as String;
      // ignore: avoid_print
      print('[respond_pending_confirmation] PC1 created -> activity_id=$activityId');

      final activityRow = await clientA.from('activity').select().eq('id', activityId).single();
      final activity = Activity.fromJson(activityRow);
      expect(activity.status, ACTIVITY_STATUS.MATCHED);
      expect(activity.school, SCHOOL.NYCU);
      expect(activity.campus, testCampus);
      expect(activity.activityLocationId, isNull);
      // ignore: avoid_print
      print(
        '[activity] status=${activity.status.name} school=${activity.school.name} '
        'campus=${activity.campus} activityLocationId=${activity.activityLocationId}',
      );

      // 8. User A proposes the candidate (auto-votes for it), user B votes
      // for the same candidate explicitly -> tally should be 2.
      final option = await proposeActivityLocation(
        clientA,
        activityId: activityId,
        locationId: locationId,
      );
      expect(option.proposedBy, userAId);
      expect(option.locationId, locationId);
      // ignore: avoid_print
      print('[propose_activity_location] A proposed option id=${option.id}');

      final vote = await voteActivityLocation(
        clientB,
        activityId: activityId,
        optionId: option.id,
      );
      expect(vote.userId, userBId);
      expect(vote.optionId, option.id);
      // ignore: avoid_print
      print('[vote_activity_location] B voted for optionId=${vote.optionId}');

      // 9. Tally via a real authenticated PostgREST read of
      // activity_location_vote (RLS is deliberately transparent to activity
      // members, see SPEC §9.1) — not a count we compute client-side from
      // the two calls above, an independent query against the DB.
      final voteRows = await clientA
          .from('activity_location_vote')
          .select()
          .eq('activity_id', activityId)
          .eq('option_id', option.id);
      expect(voteRows.length, 2, reason: 'both A (auto-vote) and B should have a vote row');
      // ignore: avoid_print
      print('[tally] ${voteRows.length} votes for optionId=${option.id}');

      // 10. Backdate start_time and trigger fn_start_activities (same
      // pg_cron-only-function escape hatch as step 4) -> the single
      // candidate should get locked and the activity should flip ONGOING.
      // fn_start_activities(), like fn_run_matching_engine(), sweeps every
      // ready activity system-wide in one call (not scoped to this test's
      // activityId) — under concurrent test-file execution a different
      // file's call can lock *this* activity first, leaving this call's own
      // returned count at 0 even though the target activity is already
      // correctly locked. Poll the target row directly instead of asserting
      // on the return count.
      await _psqlScalar(
        "update activity set start_time = now() - interval '1 minute' where id='$activityId';",
      );
      var locked = false;
      for (var attempt = 0; attempt < 10 && !locked; attempt++) {
        await _psqlScalar('select fn_start_activities();');
        final row = await clientB.from('activity').select().eq('id', activityId).single();
        locked = row['activity_location_id'] != null;
        if (!locked) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(locked, isTrue, reason: 'fn_start_activities did not lock the activity in time');

      final lockedRow = await clientB.from('activity').select().eq('id', activityId).single();
      final lockedActivity = Activity.fromJson(lockedRow);
      expect(lockedActivity.activityLocationId, option.id);
      expect(lockedActivity.status, ACTIVITY_STATUS.ONGOING);
      // ignore: avoid_print
      print(
        '[fn_start_activities] locked activityLocationId=${lockedActivity.activityLocationId} '
        'status=${lockedActivity.status.name}',
      );
    },
  );
}
