// Regression coverage for two bugs found during the 2026-07-29/30 multi-device
// testing round:
//
// 1. `notification` was never added to the `supabase_realtime` publication
//    (supabase/migrations/20260730090000_realtime_notification.sql) — the
//    通知 tab's `.stream()` subscription threw `RealtimeSubscribeException`
//    (channelError) on every device. This test proves both that a real
//    MATCH_SUCCESS notification row lands in the table (RLS: readable by its
//    own user) and that the Realtime channel actually delivers it.
//
// 2. `myActiveRequestProvider` used to treat `match_request.status == MATCHED`
//    as "still has an active flow" — but per docs/STATE_MACHINE.md,
//    MatchRequest freezes at MATCHED permanently and is never updated again,
//    even after the derived Activity finishes. That meant anyone who ever
//    completed a match was permanently blocked from creating a new one. The
//    fix (lib/match/match_providers.dart's `myActiveActivityProvider`) checks
//    `activity.status` directly instead. This test drives a real activity to
//    MATCHED, confirms the gating query finds it, then flips it to COMPLETED
//    and confirms the gating query correctly returns nothing — while
//    `match_request.status` stays permanently MATCHED throughout, proving the
//    fix doesn't accidentally depend on that field.
//
// Setup mirrors activity_location_voting_smoke_test.dart's proven PC1 path
// (two real users, real RPCs, docker-exec psql only for the pg_cron-only
// matching engine trigger and fixture seeding no client RPC can do).
//
// Run: flutter test test/notification_and_active_activity_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/supadart_header.dart';
import 'package:find_people_now/rpc/api_exception.dart';
import 'package:find_people_now/rpc/auth_profile_rpc.dart';
import 'package:find_people_now/rpc/confirmation_rpc.dart';
import 'package:find_people_now/rpc/match_request_rpc.dart';
import 'package:find_people_now/rpc/activity_type_rpc.dart';

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
  return (res.stdout as String).trim().split('\n').first.trim();
}

/// Same rationale as activity_location_voting_smoke_test.dart's identical
/// helper: `fn_run_matching_engine()` sweeps every matchable group
/// system-wide, so under `flutter test`'s concurrent file execution this
/// needs to poll+retry rather than assert on one call's return value.
Future<void> _runMatchingEngineUntil(Future<bool> Function() isReady) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await _psqlScalar('select fn_run_matching_engine();');
    if (await isReady()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('matching engine did not resolve the expected group in time');
}

/// Mirrors lib/match/match_providers.dart's `myActiveActivityProvider` query
/// exactly (activity_member join activity, filtered to JOINED +
/// MATCHED/ONGOING) — this is the regression check for the permanent-lockout
/// bug, so it must query the same way the app does, not just check the raw
/// activity row.
Future<String?> _activeActivityIdFor(SupabaseClient client, String userId) async {
  final rows = await client
      .from('activity_member')
      .select('activity_id, activity:activity_id(status)')
      .eq('user_id', userId)
      .eq('status', 'JOINED');
  for (final row in rows) {
    final activity = row['activity'] as Map<String, dynamic>?;
    final status = activity?['status'] as String?;
    if (status == 'MATCHED' || status == 'ONGOING') {
      return row['activity_id'] as String;
    }
  }
  return null;
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
    'MATCH_SUCCESS notification lands + is Realtime-delivered, and active-activity '
    'gating correctly un-blocks once the (permanently-frozen) MatchRequest\'s '
    'Activity actually completes',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'notif-active-verify-password-123!';
      const testCampus = '光復';

      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'naa-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'naa-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;

      await completeProfile(
        clientA,
        displayName: 'NAA User A',
        avatarUrl: 'https://example.com/a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'naa_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'NAA User B',
        avatarUrl: 'https://example.com/b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'naa_b_line',
      );

      // Same low-headcount ATTENDED-history seed as activity_location_voting_smoke_test.dart
      // (fresh accounts trip NEW_USER_LOW_HEADCOUNT at min_participants=2 otherwise).
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

      final requestB = await createRequest(
        clientB,
        activityTypeId: coffeeId,
        campus: testCampus,
        earliestStart: earliestStart,
        latestStart: latestStart,
        minParticipants: 2,
      );
      await submitRequest(clientB, requestB.id);

      // Subscribe to A's notification stream *before* triggering the match,
      // so the Realtime channel (not just a later poll) is what proves the
      // 20260730090000_realtime_notification.sql fix actually works.
      final notificationEvents = <List<Map<String, dynamic>>>[];
      final sub = clientA
          .from('notification')
          .stream(primaryKey: ['id'])
          .eq('user_id', userAId)
          .listen(notificationEvents.add);

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

      // --- 1. MATCH_SUCCESS notification: row exists (RLS-readable by owner) ---
      List<Map<String, dynamic>> notifRows = [];
      for (var attempt = 0; attempt < 15; attempt++) {
        notifRows = await clientA
            .from('notification')
            .select()
            .eq('user_id', userAId)
            .eq('event_type', 'MATCH_SUCCESS');
        if (notifRows.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(notifRows, isNotEmpty, reason: 'fn_create_activity_from_requests should notify both members');
      expect(notifRows.first['payload']['activity_id'], activityId);

      // --- 1b. ...and the Realtime channel actually delivered it (the bug this
      // regression test exists for: RealtimeSubscribeException before the fix).
      // 100 * 200ms = 20s: a CI runner's Realtime relay can be considerably
      // slower than a local dev machine (observed: the row lands well within
      // step 1's 3s window locally, but step 1b's original 3s window flaked
      // on GitHub Actions) — this matches the order of magnitude other
      // Realtime-delivery waits in this suite already use, e.g.
      // match_flow_integration_test.dart's _waitUntil default. ---
      var delivered = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        if (notificationEvents.any((rows) => rows.any((r) => r['event_type'] == 'MATCH_SUCCESS'))) {
          delivered = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await sub.cancel();
      expect(delivered, isTrue, reason: 'notification Realtime stream should deliver the MATCH_SUCCESS row');

      // --- 2. Active-activity gating: MatchRequest is permanently MATCHED... ---
      final frozenRequestA = await clientA.from('match_request').select().eq('id', requestA.id).single();
      expect(frozenRequestA['status'], 'MATCHED');

      // ...and while the Activity is still MATCHED/ONGOING, the gating query
      // correctly finds it (blocks a new create_request).
      final activeWhileMatched = await _activeActivityIdFor(clientA, userAId);
      expect(activeWhileMatched, activityId);

      // --- 3. Once the Activity actually finishes, gating must un-block —
      // even though match_request.status is still frozen at MATCHED above.
      // This is the exact scenario that used to permanently lock users out. ---
      await _psqlScalar("update activity set status = 'COMPLETED' where id = '$activityId';");

      final stillFrozenRequestA = await clientA.from('match_request').select().eq('id', requestA.id).single();
      expect(stillFrozenRequestA['status'], 'MATCHED', reason: 'MatchRequest never gets updated after MATCHED');

      final activeAfterCompletion = await _activeActivityIdFor(clientA, userAId);
      expect(activeAfterCompletion, isNull, reason: 'gating must not stay blocked forever once the activity is done');
    },
  );
}
