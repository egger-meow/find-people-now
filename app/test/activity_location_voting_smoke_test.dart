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
// raw SQL fixture, like the pgTAP tests use) requires routing around two
// things client code can't drive:
//   1. `fn_run_matching_engine()` is a `pg_cron`-only function, no client
//      RPC triggers it (see docs/API.md §9) — invoked here via `docker exec
//      psql`, the same escape hatch rpc_smoke_test.dart already uses for
//      seeding.
//   2. `commit_match` only creates a real `activity` row when the merged
//      pair's *total* JOINED request_member count is > 2 (SPEC §7's "greedy
//      merge" R3a branch); <=2 total goes through PENDING_CONFIRMATION
//      instead. Two solo real users merging is exactly 2, which would hit
//      that branch — and independently verified while writing this test
//      (see the flagged follow-up task) that path never actually produces
//      an Activity even after both sides confirm, so it's not usable here
//      regardless. Instead, one real user's request is padded with 2
//      raw-SQL fixture members (mirroring the exact technique
//      supabase/tests/database/01_happy_path_and_concurrency.test.sql uses)
//      so the real merge totals 4, landing squarely in the >2 branch that
//      IS verified working end-to-end (pgTAP + this test).
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
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/activity_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
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
  return (res.stdout as String).trim();
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
        contactLine: 'alv_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ALV User B',
        avatarUrl: 'https://example.com/b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
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

      // 3. Both users create+submit a real REQUESTING request via the actual
      // RPC surface. min_participants=3 (not 2) so brand-new users clear
      // submit_request's NEW_USER_LOW_HEADCOUNT gate (SPEC §12.1.1) —
      // unrelated to the eventual match size, which is decided by actual
      // request_member counts at merge time, not this field.
      final types = await searchActivityType(clientA, query: '咖啡');
      expect(types, isNotEmpty);
      final coffeeId = types.firstWhere((t) => t.name == '咖啡').id;

      final requestA = await createRequest(
        clientA,
        activityTypeId: coffeeId,
        campus: testCampus,
        bucket: RequestBucket.NOW,
        minParticipants: 3,
      );
      await submitRequest(clientA, requestA.id);
      // ignore: avoid_print
      print('[create_request/submit_request] A -> ${requestA.id} REQUESTING');

      // 4. Pad A's request with 2 fixture members via raw SQL (mirrors
      // 01_happy_path_and_concurrency.test.sql's exact technique) so the
      // real merge below lands in commit_match's >2 branch (direct Activity
      // creation), not the <=2 PENDING_CONFIRMATION branch — see the file
      // header comment for why the latter is routed around entirely.
      await _psqlScalar('''
        do \$\$
        declare
          v_ex1 uuid := gen_random_uuid();
          v_ex2 uuid := gen_random_uuid();
        begin
          insert into auth.users (id, email) values
            (v_ex1, 'alv-ex1-$stamp@nycu.edu.tw'), (v_ex2, 'alv-ex2-$stamp@nycu.edu.tw');
          insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_line) values
            (v_ex1, 'alv-ex1-$stamp@nycu.edu.tw', 'NYCU', 'Ex1', 'https://x', 'MASTER', 'alv_ex1_line'),
            (v_ex2, 'alv-ex2-$stamp@nycu.edu.tw', 'NYCU', 'Ex2', 'https://x', 'MASTER', 'alv_ex2_line');
          insert into request_member (request_id, user_id, role, status) values
            ('${requestA.id}', v_ex1, 'MEMBER', 'JOINED'),
            ('${requestA.id}', v_ex2, 'MEMBER', 'JOINED');
        end \$\$;
      ''');
      // ignore: avoid_print
      print('[fixture] padded request A to 3 JOINED members');

      final requestB = await createRequest(
        clientB,
        activityTypeId: coffeeId,
        campus: testCampus,
        bucket: RequestBucket.NOW,
        minParticipants: 3,
      );
      await submitRequest(clientB, requestB.id);
      // ignore: avoid_print
      print('[create_request/submit_request] B -> ${requestB.id} REQUESTING');

      // 5. Trigger the matching engine (pg_cron-only, no client RPC exists —
      // see docs/API.md §9). Total merged size = 3 (A + 2 fixtures) + 1 (B)
      // = 4 > 2, so commit_match creates a real Activity directly.
      final matchCount = await _psqlScalar('select fn_run_matching_engine();');
      expect(matchCount, '1', reason: 'expected exactly one merge to fire');

      // 6. Fetch the resulting activity via a real authenticated PostgREST
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
      print('[fn_run_matching_engine] merged -> activity_id=$activityId');

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

      // 7. User A proposes the candidate (auto-votes for it), user B votes
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
        locationId: locationId,
      );
      expect(vote.userId, userBId);
      expect(vote.locationId, locationId);
      // ignore: avoid_print
      print('[vote_activity_location] B voted for locationId=${vote.locationId}');

      // 8. Tally via a real authenticated PostgREST read of
      // activity_location_vote (RLS is deliberately transparent to activity
      // members, see SPEC §9.1) — not a count we compute client-side from
      // the two calls above, an independent query against the DB.
      final voteRows = await clientA
          .from('activity_location_vote')
          .select()
          .eq('activity_id', activityId)
          .eq('location_id', locationId);
      expect(voteRows.length, 2, reason: 'both A (auto-vote) and B should have a vote row');
      // ignore: avoid_print
      print('[tally] ${voteRows.length} votes for locationId=$locationId');

      // 9. Backdate start_time and trigger fn_start_activities (same
      // pg_cron-only-function escape hatch as step 5) -> the single
      // candidate should get locked and the activity should flip ONGOING.
      await _psqlScalar(
        "update activity set start_time = now() - interval '1 minute' where id='$activityId';",
      );
      final startedCount = await _psqlScalar('select fn_start_activities();');
      expect(int.parse(startedCount), greaterThanOrEqualTo(1));

      final lockedRow = await clientB.from('activity').select().eq('id', activityId).single();
      final lockedActivity = Activity.fromJson(lockedRow);
      expect(lockedActivity.activityLocationId, locationId);
      expect(lockedActivity.status, ACTIVITY_STATUS.ONGOING);
      // ignore: avoid_print
      print(
        '[fn_start_activities] locked activityLocationId=${lockedActivity.activityLocationId} '
        'status=${lockedActivity.status.name}',
      );
    },
  );
}
