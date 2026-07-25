// Verification run for the hand-written RPC wrapper layer in lib/rpc/,
// against a real local `supabase start` instance (not mocked).
//
// Creates a throwaway auth user via the GoTrue admin API (service-role key,
// test-only — see .env), signs in as them, then drives the same
// create_request / submit_request path pgTAP's
// supabase/tests/database/01_happy_path_and_concurrency.test.sql exercises
// at the SQL level, but through the Dart RPC wrapper instead.
//
// Run: flutter test test/rpc_smoke_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';

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
    'complete_profile -> get_my_reliability -> search_activity_type -> create_request -> submit_request',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final email = 'flutter-verify-$stamp@nycu.edu.tw';
      const password = 'flutter-verify-password-123!';

      // 1. Create a throwaway auth user via the GoTrue admin API (test-only
      //    shortcut for OTP login, matching what the task scope allows).
      final createRes = await http.post(
        Uri.parse('$supabaseUrl/auth/v1/admin/users'),
        headers: {
          'apikey': serviceRoleKey,
          'Authorization': 'Bearer $serviceRoleKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email,
          'password': password,
          'email_confirm': true,
        }),
      );
      expect(
        createRes.statusCode,
        anyOf(200, 201),
        reason: 'admin user create failed: ${createRes.body}',
      );
      final userId = jsonDecode(createRes.body)['id'] as String;
      // ignore: avoid_print
      print('[setup] created auth user $email ($userId)');

      // 2. Real sign-in (password grant), not a hand-crafted JWT.
      final client = SupabaseClient(supabaseUrl, anonKey);
      final authRes = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      expect(authRes.session, isNotNull);
      // ignore: avoid_print
      print('[setup] signed in, auth.uid() = ${authRes.user!.id}');

      // 3. rpc: complete_profile
      final profile = await completeProfile(
        client,
        displayName: 'Flutter Verify User',
        avatarUrl: 'https://example.com/avatar.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        contactLine: 'flutter_verify_line',
      );
      expect(profile.id, userId);
      expect(profile.school, SCHOOL.NYCU); // derived from @nycu.edu.tw
      expect(profile.degreeLevel, DEGREE_LEVEL.MASTER);
      // ignore: avoid_print
      print(
        '[complete_profile] school=${profile.school.name} '
        'degreeLevel=${profile.degreeLevel.name} displayName=${profile.displayName}',
      );

      // 4. rpc: get_my_reliability — brand new user, 0 reliability events.
      final reliability = await getMyReliability(client);
      expect(reliability.tier, ReliabilityTier.newUser);
      expect(reliability.isNewUser, isTrue);
      // ignore: avoid_print
      print(
        '[get_my_reliability] tier=${reliability.tier.name} '
        'isNewUser=${reliability.isNewUser}',
      );

      // 5. rpc: search_activity_type — find the seeded '咖啡' type (2/4, no
      //    group_size_step, so create_request's step-validation branch is
      //    skipped and this stays a focused create_request/submit_request test).
      final types = await searchActivityType(client, query: '咖啡');
      expect(types, isNotEmpty);
      final coffee = types.firstWhere((t) => t.name == '咖啡');
      // ignore: avoid_print
      print('[search_activity_type] found 咖啡 id=${coffee.id}');

      // 6. Look up the NYCU test location seeded for this run.
      //
      // WORKAROUND, not a frontend bug: `client.from('location').select()`
      // 403s here with "permission denied for table location" (code 42501)
      // for BOTH `authenticated` AND `service_role` — confirmed by trying
      // service_role first, same error. RLS itself is fine
      // (`active_locations_select` policy exists) but NO migration under
      // supabase/migrations/ ever runs a `grant select`: `\dp location` on
      // the local instance shows anon/authenticated/service_role only have
      // D/x/t/m (delete/references/trigger/maintain), no SELECT. This
      // breaks every `(PostgREST)`-tagged endpoint in docs/API.md (2.1, 2.4,
      // 3.6, 5.2, 6.1, 8.1, 8.2, ...) for every real client role; pgTAP's
      // tests never catch it because they run as the `postgres` superuser
      // inside BEGIN/ROLLBACK, bypassing PostgREST's role layer entirely.
      // Reported separately in RPC_COVERAGE.md — going around it here via a
      // direct psql read (same pattern pgTAP fixtures use for setup) so this
      // test's actual subject (create_request/submit_request, both
      // SECURITY DEFINER and unaffected by the GRANT bug) stays verifiable
      // without masking the bug behind an out-of-band GRANT.
      final psql = await Process.run('docker', [
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
        "select id from location where school='NYCU' and name='Flutter 驗證測試地點' limit 1;",
      ]);
      expect(
        psql.exitCode,
        0,
        reason: 'run the location seed first: ${psql.stderr}',
      );
      final locationId = (psql.stdout as String).trim();
      expect(locationId, isNotEmpty, reason: 'run the location seed first');

      // 7. rpc: create_request
      final request = await createRequest(
        client,
        activityTypeId: coffee.id,
        campusLocationId: locationId,
        bucket: RequestBucket.NOW,
        minParticipants: 2,
      );
      expect(request.status, REQUEST_STATUS.DRAFT);
      expect(request.ownerId, userId);
      expect(request.activityTypeId, coffee.id);
      expect(request.campusLocationId, locationId);
      expect(request.minParticipants, 2);
      // ignore: avoid_print
      print(
        '[create_request] id=${request.id} status=${request.status.name} '
        'minParticipants=${request.minParticipants}',
      );

      // 8. rpc: submit_request — brand-new user + min_participants<=2 must
      //    hit NEW_USER_LOW_HEADCOUNT (SPEC §12.1 / API.md §3.2 step 9).
      //    Exercises the ApiException/ApiErrorCode round trip end to end,
      //    not just the happy path.
      try {
        await submitRequest(client, request.id);
        fail('expected submit_request to throw NEW_USER_LOW_HEADCOUNT');
      } on ApiException catch (e) {
        expect(e.code, ApiErrorCode.newUserLowHeadcount);
        // ignore: avoid_print
        print('[submit_request] got expected ApiException: $e');
      }
    },
  );
}
