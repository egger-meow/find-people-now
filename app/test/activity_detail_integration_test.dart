// Verification run for the "我的活動" round-2 slice (UI_PLAN §4.1 Tab 1
// 「地點」— lib/activities/activity_detail_providers.dart +
// activity_detail_screen.dart), against a real local `supabase start`
// instance (not mocked). Same style as
// test/activity_location_voting_smoke_test.dart / my_activities_integration_test.dart.
//
// activity_location_voting_smoke_test.dart already drives
// propose_activity_location/vote_activity_location/fn_start_activities lock
// end-to-end, so this file does not repeat that — it focuses on what's
// genuinely new this round and had zero prior test coverage:
//
//   1. update_meeting_point: real per-user 2-minute cooldown (real
//      MEETING_POINT_UPDATE_COOLDOWN rejection, not assumed from reading the
//      migration), append-only history, and the exact query
//      activityMeetingPointUpdatesStreamProvider issues.
//   2. update_meeting_hint: per-member field (each user's own row, doesn't
//      leak to the other member), 30-char INVALID_INPUT rejection, and the
//      exact query _MeetingHintSectionState._load issues.
//   3. The locked-location lookup query _LockedLocationCard depends on
//      (approvedLocationsProvider's school+campus+APPROVED select, joined
//      client-side to activity.activityLocationId) against a real locked
//      activity.
//
// Run: flutter test test/activity_detail_integration_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:find_people_now/generated/activity.dart';
import 'package:find_people_now/generated/activity_location_option.dart';
import 'package:find_people_now/generated/activity_meeting_point_update.dart';
import 'package:find_people_now/generated/location.dart';
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

/// `docker exec ... psql -t -A -c "<sql>"` — same escape hatch used
/// elsewhere, for the one thing no client RPC can do: triggering the
/// pg_cron-only matching engine / start-activities jobs.
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

/// The exact query `activityMeetingPointUpdatesStreamProvider` issues
/// (lib/activities/activity_detail_providers.dart), minus the `.stream()`
/// wrapper — sorted newest-first the same way the provider's `.map` does.
Future<List<ActivityMeetingPointUpdate>> _meetingPointUpdatesQuery(
  SupabaseClient client,
  String activityId,
) async {
  final rows =
      await client.from('activity_meeting_point_update').select().eq('activity_id', activityId);
  final list = rows.map(ActivityMeetingPointUpdate.fromJson).toList();
  list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return list;
}

/// The exact query `_MeetingHintSectionState._load` issues.
Future<String?> _ownMeetingHintQuery(
  SupabaseClient client,
  String activityId,
  String userId,
) async {
  final row = await client
      .from('activity_member')
      .select()
      .eq('activity_id', activityId)
      .eq('user_id', userId)
      .maybeSingle();
  return row?['meeting_hint'] as String?;
}

/// The exact query `approvedLocationsProvider` issues.
Future<List<Location>> _approvedLocationsQuery(
  SupabaseClient client,
  SCHOOL school,
  String campus,
) async {
  final rows = await client
      .from('location')
      .select()
      .eq('school', school.name)
      .eq('campus', campus)
      .eq('status', 'APPROVED');
  return rows.map(Location.fromJson).toList();
}

/// The exact query `activityLocationOptionsStreamProvider` issues (v1.30:
/// `activity.activityLocationId` now points at an `activity_location_option`
/// row, not directly at a `location` row — `_LockedLocationCard` resolves the
/// display name through this table first).
Future<List<ActivityLocationOption>> _activityLocationOptionsQuery(
  SupabaseClient client,
  String activityId,
) async {
  final rows = await client.from('activity_location_option').select().eq('activity_id', activityId);
  return rows.map(ActivityLocationOption.fromJson).toList();
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
    'meeting point cooldown + per-user independence, meeting hint per-member '
    'isolation + length gate, and the locked-location lookup query — all '
    'against a real MATCHED/ONGOING activity',
    () async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      const password = 'activity-detail-verify-password-123!';

      final clientA = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ad-a-$stamp@nycu.edu.tw',
        password,
      );
      final clientB = await _createAndSignIn(
        supabaseUrl,
        anonKey,
        serviceRoleKey,
        'ad-b-$stamp@nycu.edu.tw',
        password,
      );
      final userAId = clientA.auth.currentUser!.id;
      final userBId = clientB.auth.currentUser!.id;
      // ignore: avoid_print
      print('[setup] userA=$userAId userB=$userBId');

      await completeProfile(
        clientA,
        displayName: 'ActivityDetail User A',
        avatarUrl: 'https://example.com/ad-a.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ad_a_line',
      );
      await completeProfile(
        clientB,
        displayName: 'ActivityDetail User B',
        avatarUrl: 'https://example.com/ad-b.png',
        degreeLevel: DEGREE_LEVEL.MASTER,
        bio: 'Hi there',
        contactLine: 'ad_b_line',
      );

      // 自己的校區字串（不用共用的 '光復'）——matching engine 是依
      // (activity_type_id, school, campus) 分組掃描 REQUESTING 池，多個測試
      // 檔平行執行時若共用同一組會互相撈到對方剛建立的 request，
      // 造成「expected exactly one merge to fire」斷言不穩。自己種一筆這個
      // 校區專屬的 location，不依賴 app/README.md 記載的手動種子步驟。
      final testCampus = 'ADT測試區$stamp';
      final locationId = await _psqlScalar('''
        insert into location (school, campus, name, status, is_active)
        select 'NYCU', '$testCampus', 'ADT測試地點$stamp', 'APPROVED', true
        returning id;
      ''');
      expect(locationId, isNotEmpty);

      // Seed ATTENDED history so min_participants=2 doesn't trip
      // NEW_USER_LOW_HEADCOUNT (same fixture pattern as the other two
      // integration test files).
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
      // 1. update_meeting_point: real cooldown, append-only, per-user
      //    independence — none of this was ever exercised by any test.
      // -----------------------------------------------------------------
      final firstUpdate = await updateMeetingPoint(
        clientA,
        activityId: activityId,
        description: '正門警衛室旁',
      );
      expect(firstUpdate.updatedBy, userAId);
      expect(firstUpdate.description, '正門警衛室旁');

      // Same user, immediately again -> real MEETING_POINT_UPDATE_COOLDOWN,
      // not assumed from reading the migration.
      await expectLater(
        updateMeetingPoint(clientA, activityId: activityId, description: '改個地方'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.meetingPointUpdateCooldown),
        ),
      );
      // ignore: avoid_print
      print('[update_meeting_point] same-user immediate re-call correctly hit the cooldown');

      // A different user is NOT subject to A's cooldown — independent
      // per-(activity, user) gate, not a single per-activity lock.
      final secondUpdate = await updateMeetingPoint(
        clientB,
        activityId: activityId,
        description: '一樓大廳',
      );
      expect(secondUpdate.updatedBy, userBId);

      final history = await _meetingPointUpdatesQuery(clientA, activityId);
      expect(history.length, 2, reason: 'append-only: both updates kept, not overwritten');
      expect(history.first.description, '一樓大廳', reason: 'newest-first sort matches the provider');
      // ignore: avoid_print
      print('[activity_meeting_point_update] ${history.length} rows, newest="${history.first.description}"');

      // -----------------------------------------------------------------
      // 2. update_meeting_hint: per-member field, 30-char gate.
      // -----------------------------------------------------------------
      await updateMeetingHint(clientA, activityId: activityId, hint: '紅色棒球帽');
      final hintA = await _ownMeetingHintQuery(clientA, activityId, userAId);
      expect(hintA, '紅色棒球帽');
      final hintBUnaffected = await _ownMeetingHintQuery(clientB, activityId, userBId);
      expect(hintBUnaffected, isNull, reason: "A's hint update must not leak onto B's own row");
      // ignore: avoid_print
      print('[update_meeting_hint] A set "$hintA", B unaffected (isolation confirmed)');

      await expectLater(
        updateMeetingHint(clientA, activityId: activityId, hint: 'a' * 31),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.invalidInput)),
      );
      // ignore: avoid_print
      print('[update_meeting_hint] 31-char hint correctly rejected with INVALID_INPUT');

      // -----------------------------------------------------------------
      // 3. Lock the location (real propose/vote/fn_start_activities flow is
      //    already covered end-to-end by activity_location_voting_smoke_test.dart
      //    — here just enough to reach a locked activity) and verify the
      //    exact lookup query _LockedLocationCard performs.
      // -----------------------------------------------------------------
      final option = await proposeActivityLocation(clientA, activityId: activityId, locationId: locationId);
      expect(option.locationId, locationId);
      await voteActivityLocation(clientB, activityId: activityId, optionId: option.id);

      // fn_start_activities() sweeps every ready activity system-wide in one
      // call, not scoped to this activityId — under concurrent test-file
      // execution a different file's call can lock this one first, leaving
      // this call's own return count at 0. Poll the target row directly.
      await _psqlScalar(
        "update activity set start_time = now() - interval '1 minute' where id='$activityId';",
      );
      var locked = false;
      for (var attempt = 0; attempt < 10 && !locked; attempt++) {
        await _psqlScalar('select fn_start_activities();');
        final row = await clientA.from('activity').select().eq('id', activityId).single();
        locked = row['activity_location_id'] != null;
        if (!locked) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(locked, isTrue, reason: 'fn_start_activities did not lock the activity in time');

      final lockedRow = await clientA.from('activity').select().eq('id', activityId).single();
      final lockedActivity = Activity.fromJson(lockedRow);
      expect(lockedActivity.activityLocationId, option.id);
      expect(lockedActivity.status, ACTIVITY_STATUS.ONGOING);

      final options = await _activityLocationOptionsQuery(clientA, activityId);
      final lockedOptionMatch = options.where((o) => o.id == lockedActivity.activityLocationId);
      expect(lockedOptionMatch, isNotEmpty, reason: '_LockedLocationCard must be able to resolve the winning option');
      expect(lockedOptionMatch.single.locationId, locationId);

      final approved = await _approvedLocationsQuery(clientA, lockedActivity.school, lockedActivity.campus);
      final lockedMatch = approved.where((l) => l.id == lockedOptionMatch.single.locationId);
      expect(lockedMatch, isNotEmpty, reason: '_LockedLocationCard must be able to resolve the name');
      expect(lockedMatch.single.name, 'ADT測試地點$stamp');
      // ignore: avoid_print
      print('[approvedLocationsProvider lookup] resolved locked location name="${lockedMatch.single.name}"');

      // update_meeting_point/update_meeting_hint stay callable after the
      // lock (ACTIVITY_NOT_ACTIVE only gates statuses outside MATCHED/ONGOING,
      // per supabase/migrations/20260724121800_meeting_point_rpc.sql) — real
      // check, not assumed, since B's earlier cooldown window has since
      // passed relative to this later call in practice it may still be
      // active; assert on the meeting hint path instead, which has no
      // cooldown.
      await updateMeetingHint(clientB, activityId: activityId, hint: '藍色背包');
      final hintBAfterLock = await _ownMeetingHintQuery(clientB, activityId, userBId);
      expect(hintBAfterLock, '藍色背包');
      // ignore: avoid_print
      print('[update_meeting_hint] still callable after ONGOING lock');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
