// Verification run for Arrival Check「我到了」(docs/API.md §6.8, SPEC v1.24)
// against a real local `supabase start` instance (not mocked). Same style as
// activity_members_integration_test.dart / notification_and_active_activity_test.dart.
//
// pgTAP (supabase/tests/database/24_arrival_check.test.sql) already covers
// the RPC's SQL-level authorization/idempotency/boundary logic exhaustively.
// This test instead exercises the parts pgTAP can't: the real Dart
// `markArrived()` wrapper on the wire, the real `activity_member` Realtime
// channel (only just added to the publication this round — the roster
// provider used to be plain FutureProvider/no-Realtime, see
// RPC_COVERAGE.md's v1.24 entry), and the shape `notifications_screen.dart`
// actually reads off `payload`.
//
// The Realtime step subscribes via a raw `RealtimeChannel` and waits for
// `RealtimeSubscribeStatus.subscribed` before writing, rather than using
// `.stream()` — same root cause and same fix as
// notification_and_active_activity_test.dart (see that file's header):
// `.stream()`'s initial fetch races the WebSocket handshake and never
// re-fetches on first connect, so a write that lands before the channel is
// truly live misses its event permanently, and no amount of post-write
// polling recovers it. This file hit exactly that flake in a full-suite run
// (passed standalone, failed under `flutter test -j 1`) before this fix.
//
// Run: flutter test test/arrival_check_integration_test.dart
import 'dart:async';
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
  return (res.stdout as String).trim().split('\n').first.trim();
}

/// See activity_members_integration_test.dart's identical helper for why
/// polling (not asserting a single call's return value) is required here.
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
    'mark_arrived: real DB write + Realtime delivery on activity_member + MEMBER_ARRIVED notification',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'arrival-check-verify-password-123!';

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

      await completeProfile(
        clientA,
        displayName: 'ArrivalCheck User A',
        avatarUrl: 'https://example.com/ac-a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ac_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ArrivalCheck User B',
        avatarUrl: 'https://example.com/ac-b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ac_b_line',
      );

      final testCampus = 'ACT測試區$stamp';
      await _psqlScalar('''
        insert into location (school, campus, name, status, is_active)
        values ('NYCU', '$testCampus', 'ACT測試地點$stamp', 'APPROVED', true);
      ''');

      final types = await searchActivityType(clientA, query: '咖啡');
      final coffeeId = types.firstWhere((t) => t.name == '咖啡').id;

      // minParticipants=2 with two brand-new accounts would otherwise trip
      // submit_request's NEW_USER_LOW_HEADCOUNT gate (fn_is_new_user = true
      // for anyone with zero 'ATTENDED' rows) — seed one historical ATTENDED
      // event per user first, same escape hatch
      // activity_location_voting_smoke_test.dart uses.
      await _psqlScalar('''
        with hist_activity as (
          insert into activity (activity_type_id, school, campus, start_time, estimated_end_time, status)
          values ('$coffeeId', 'NYCU', '$testCampus', now() - interval '10 days',
                  now() - interval '10 days' + interval '1 hour', 'COMPLETED')
          returning id
        )
        insert into user_reliability_event (user_id, activity_id, event_type)
        select uid, hist_activity.id, 'ATTENDED'
        from hist_activity, (values ('$userAId'::uuid), ('$userBId'::uuid)) as u(uid);
      ''');

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
      await respondPendingConfirmation(clientA, pendingConfirmationId: statusForA.pendingConfirmationId, confirm: true);
      await respondPendingConfirmation(clientB, pendingConfirmationId: statusForB.pendingConfirmationId, confirm: true);

      final memberRows = await clientB.from('activity_member').select('activity_id').eq('user_id', userBId);
      final activityId = memberRows.first['activity_id'] as String;
      // ignore: avoid_print
      print('[setup] reached MATCHED activity_id=$activityId');

      // -----------------------------------------------------------------
      // Subscribe to activity_member UPDATEs BEFORE calling mark_arrived, so
      // the Realtime channel — not a later poll — is what proves
      // 20260801100200_realtime_activity_member.sql actually works. Wait for
      // the server to confirm the channel is live first (see file header).
      // -----------------------------------------------------------------
      final memberUpdates = <Map<String, dynamic>>[];
      final channelSubscribed = Completer<void>();
      final channel = clientB.channel('ac-member-$stamp');
      channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'activity_member',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'activity_id',
          value: activityId,
        ),
        callback: (payload) => memberUpdates.add(payload.newRecord),
      );
      channel.subscribe((status, [error]) {
        if (channelSubscribed.isCompleted) return;
        if (status == RealtimeSubscribeStatus.subscribed) {
          channelSubscribed.complete();
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          channelSubscribed.completeError(RealtimeSubscribeException(status, error));
        }
      });
      await channelSubscribed.future.timeout(const Duration(seconds: 20));
      // The `subscribed` ack only means the Phoenix channel join completed;
      // Realtime's server-side WAL listener wiring this filter into its
      // broadcast list lags slightly behind that. Same empirically-derived
      // buffer as notification_and_active_activity_test.dart.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // -----------------------------------------------------------------
      // 1. A marks arrived. Real DB write via the real markArrived() wrapper.
      // -----------------------------------------------------------------
      final resultA = await markArrived(clientA, activityId: activityId);
      expect(resultA.arrivedAt, isNotNull);
      // ignore: avoid_print
      print('[mark_arrived] A arrived at ${resultA.arrivedAt}');

      // Channel was confirmed SUBSCRIBED before the write above, so this is
      // just waiting out normal WAL-to-websocket latency — 100 * 200ms = 20s
      // of headroom for a slower CI relay.
      var delivered = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        if (memberUpdates.any((r) => r['user_id'] == userAId && r['arrived_at'] != null)) {
          delivered = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await channel.unsubscribe();
      expect(delivered, isTrue, reason: 'activity_member Realtime channel should deliver the arrived_at update');

      // -----------------------------------------------------------------
      // 2. B should have exactly one MEMBER_ARRIVED notification about A;
      //    A should have zero (no self-notification).
      // -----------------------------------------------------------------
      final notificationsForB = await clientB
          .from('notification')
          .select()
          .eq('user_id', userBId)
          .eq('event_type', 'MEMBER_ARRIVED');
      expect(notificationsForB.length, 1);
      final payload = notificationsForB.first['payload'] as Map<String, dynamic>;
      expect(payload['activity_id'], activityId);
      expect(payload['arrived_user_id'], userAId);
      expect(payload['display_name'], 'ArrivalCheck User A');
      // ignore: avoid_print
      print('[MEMBER_ARRIVED] B received notification with payload matching notifications_screen.dart\'s s() reads');

      final notificationsForA = await clientA
          .from('notification')
          .select()
          .eq('user_id', userAId)
          .eq('event_type', 'MEMBER_ARRIVED');
      expect(notificationsForA, isEmpty, reason: 'arriver must not receive a self-notification');

      // -----------------------------------------------------------------
      // 3. Idempotency through the real wrapper: repeat call returns the
      //    same arrived_at, no second notification.
      // -----------------------------------------------------------------
      final resultARepeat = await markArrived(clientA, activityId: activityId);
      expect(resultARepeat.arrivedAt, resultA.arrivedAt);
      final notificationsForBAfterRepeat = await clientB
          .from('notification')
          .select()
          .eq('user_id', userBId)
          .eq('event_type', 'MEMBER_ARRIVED');
      expect(notificationsForBAfterRepeat.length, 1, reason: 'repeat mark_arrived must not duplicate the notification');
      // ignore: avoid_print
      print('[mark_arrived] repeat call correctly idempotent end-to-end');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
