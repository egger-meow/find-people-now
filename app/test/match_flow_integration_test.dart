// Verification run for the "配對頁 + 等待室" round-1 frontend slice, against a
// real local `supabase start` instance (not mocked) — same style as
// test/rpc_smoke_test.dart.
//
// Drives the exact path UI_PLAN.md §2/§3 describe end to end through the
// hand-written RPC wrapper layer (not through widgets — this repo's existing
// convention for RPC/Realtime integration tests, see rpc_smoke_test.dart):
//   填表送出 (create_request -> submit_request)
//   -> 進等待室 (REQUESTING status, confirmed via the *same* Realtime
//      `.stream()` call lib/match/match_providers.dart's
//      matchRequestStreamProvider uses)
//   -> 邀請連結產生 (get_or_create_invite_link)
//   -> Realtime 收到狀態變化 (a direct DB update simulating what the
//      matching-engine background job does is picked up by the still-open
//      stream subscription, without polling/refetching)
//
// Run: flutter test test/match_flow_integration_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';

/// Polls [condition] until it's true or [timeout] elapses, instead of a fixed
/// sleep — Realtime delivery latency is not deterministic.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future.delayed(interval);
  }
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
    'create_request -> submit_request -> waiting room Realtime -> invite link -> Realtime status change',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final email = 'waiting-room-verify-$stamp@nycu.edu.tw';
      const password = 'waiting-room-verify-password-123!';

      // 1. Throwaway auth user via the GoTrue admin API (same test-only
      //    shortcut rpc_smoke_test.dart uses — real OTP email round-trips are
      //    exercised separately by hand against Mailpit, not in this suite).
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
      expect(createRes.statusCode, anyOf(200, 201), reason: 'admin user create failed: ${createRes.body}');
      final userId = jsonDecode(createRes.body)['id'] as String;
      // ignore: avoid_print
      print('[setup] created auth user $email ($userId)');

      final client = SupabaseClient(supabaseUrl, anonKey);
      final authRes = await client.auth.signInWithPassword(email: email, password: password);
      expect(authRes.session, isNotNull);
      // ignore: avoid_print
      print('[setup] signed in, auth.uid() = ${authRes.user!.id}');

      // 2. Minimal profile-completion gate (same one CompleteProfileScreen
      //    drives) — create_request hard-requires an app_user row to exist.
      final profile = await completeProfile(
        client,
        displayName: 'Waiting Room Verify',
        avatarUrl: 'https://example.com/avatar.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'waiting_room_verify_line',
      );
      expect(profile.school, SCHOOL.NYCU);
      // ignore: avoid_print
      print('[complete_profile] school=${profile.school.name}');

      // 3. 填表送出 — minParticipants=3 (not <=2) so submit_request doesn't
      //    hit NEW_USER_LOW_HEADCOUNT for this brand-new user, keeping this
      //    test focused on the waiting-room/Realtime path.
      final types = await searchActivityType(client, query: '咖啡');
      final coffee = types.firstWhere((t) => t.name == '吃飯/咖啡/探店');
      final now = DateTime.now().toUtc();
      final created = await createRequest(
        client,
        activityTypeId: coffee.id,
        campus: '光復', // seeded NYCU campus, supabase/migrations/20260724121600_seed_locations.sql
        earliestStart: now,
        latestStart: now.add(const Duration(hours: 2)),
        minParticipants: 3,
      );
      expect(created.status, REQUEST_STATUS.DRAFT);

      final submitted = await submitRequest(client, created.id);
      expect(submitted.status, REQUEST_STATUS.REQUESTING);
      // ignore: avoid_print
      print('[submit_request] id=${submitted.id} status=${submitted.status.name}');

      // 4. 進等待室 — subscribe with the *same* Realtime call
      //    lib/match/match_providers.dart's matchRequestStreamProvider uses,
      //    not a re-fetch/poll. Collect every status this stream emits.
      final observedStatuses = <REQUEST_STATUS>[];
      final subscription = client
          .from('match_request')
          .stream(primaryKey: ['id'])
          .eq('id', submitted.id)
          .listen((rows) {
            if (rows.isNotEmpty) {
              observedStatuses.add(MatchRequest.fromJson(rows.first).status);
            }
          });
      addTearDown(subscription.cancel);

      await _waitUntil(() => observedStatuses.isNotEmpty);
      expect(observedStatuses.first, REQUEST_STATUS.REQUESTING);
      // ignore: avoid_print
      print('[waiting room] initial Realtime snapshot status=${observedStatuses.first.name}');

      // 5. 邀請連結產生
      final inviteToken = await getOrCreateInviteLink(client, submitted.id);
      expect(inviteToken, isNotEmpty);
      // ignore: avoid_print
      print('[get_or_create_invite_link] token=$inviteToken');

      // 6. Realtime 收到狀態變化 — a direct DB write standing in for what the
      //    matching-engine background job does (see
      //    supabase/migrations/20260724124000_create_request_earliest_latest.sql
      //    and fn_run_matching_engine), asserting the *already-open*
      //    subscription reacts without any re-fetch on this test's side.
      final updateRes = await Process.run('docker', [
        'exec',
        'supabase_db_find-people-now',
        'psql',
        '-U',
        'postgres',
        '-d',
        'postgres',
        '-c',
        "update match_request set status = 'EXPIRED' where id = '${submitted.id}';",
      ]);
      expect(updateRes.exitCode, 0, reason: 'direct status-change simulation failed: ${updateRes.stderr}');

      // Generous timeout: right after a fresh `supabase db reset`, the
      // Realtime container's logical-replication connection to Postgres is
      // still warming up (observed 10-15s cold-start in this environment) —
      // this is one-time connection setup latency, not steady-state delivery
      // latency (verified separately: once warm, delivery is near-instant).
      await _waitUntil(
        () => observedStatuses.contains(REQUEST_STATUS.EXPIRED),
        timeout: const Duration(seconds: 25),
      );
      expect(observedStatuses.last, REQUEST_STATUS.EXPIRED);
      // ignore: avoid_print
      print('[waiting room] Realtime picked up status change -> ${observedStatuses.last.name}');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
