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
        bio: 'Hi there',
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

      // 5. rpc: search_activity_type — find the seeded '吃飯/咖啡/探店' type
      //    (3/6 as of v1.42, no group_size_step, so create_request's
      //    step-validation branch is skipped and this stays a focused
      //    create_request/submit_request test). minParticipants below is
      //    passed explicitly (2), not derived from the type's own default —
      //    the RPC's own floor is 2 regardless of the type's configured
      //    default_min_participants (see SPEC v1.41).
      final types = await searchActivityType(client, query: '咖啡');
      expect(types, isNotEmpty);
      final coffee = types.firstWhere((t) => t.name == '吃飯/咖啡/探店');
      // ignore: avoid_print
      print('[search_activity_type] found 吃飯/咖啡/探店 id=${coffee.id}');

      // 6. Confirm the NYCU test location seeded for this run exists (v1.11:
      // create_request no longer takes a precise location id — it takes a
      // Matching Scope `campus` string, validated server-side against
      // `exists(location where school=... and campus=... and status='APPROVED')`
      // — so this step just guards that the seed step below actually ran,
      // it doesn't fetch an id to pass through anymore.
      //
      // HISTORICAL NOTE: `client.from('location').select()` used to 403 here
      // with "permission denied for table location" (42501) for every client
      // role — no migration under supabase/migrations/ ran a `grant select`
      // on any table, breaking every `(PostgREST)`-tagged endpoint in
      // docs/API.md. Fixed in 20260724120800_grants.sql (v1.9) — see that
      // migration's header comment for the full root-cause writeup and
      // RPC_COVERAGE.md for the fix summary. `client.from('location')...`
      // would work now too; this still reads via `docker exec ... psql`
      // instead purely because no migration seeds `location` rows (only
      // `activity_type` does), so a raw read after the raw seed insert below
      // is the simplest fixture setup, not a permissions workaround anymore.
      const testCampus = '光復';
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
        "select id from location where school='NYCU' and campus='$testCampus' "
            "and name='Flutter 驗證測試地點' limit 1;",
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
        campus: testCampus,
        earliestStart: DateTime.now().toUtc(),
        latestStart: DateTime.now().toUtc().add(const Duration(hours: 2)),
        minParticipants: 2,
      );
      expect(request.status, REQUEST_STATUS.DRAFT);
      expect(request.ownerId, userId);
      expect(request.activityTypeId, coffee.id);
      expect(request.campus, testCampus);
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
