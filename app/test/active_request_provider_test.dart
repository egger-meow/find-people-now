import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/activities/my_activities_providers.dart';
import 'package:find_people_now/generated/match_request.dart';
import 'package:find_people_now/generated/supadart_header.dart';

void main() {
  group('myActiveRequestProvider logic & filtering', () {
    MatchRequest createReq({
      required String id,
      required REQUEST_STATUS status,
      String? inviteToken,
      DateTime? revokedAt,
      DateTime? latestStart,
      DateTime? createdAt,
    }) {
      final now = DateTime.now();
      return MatchRequest(
        id: id,
        ownerId: 'user-1',
        activityTypeId: 'act-1',
        earliestStart: now,
        latestStart: latestStart ?? now.add(const Duration(hours: 2)),
        flexibleMinutes: 0,
        minParticipants: 2,
        maxParticipants: 4,
        allowDowngrade: false,
        status: status,
        inviteToken: inviteToken,
        revokedAt: revokedAt,
        createdAt: createdAt ?? now,
        school: SCHOOL.NYCU,
        campus: '光復校區',
      );
    }

    MatchRequest? resolveActiveRequest(List<MatchRequest> requests) {
      final sorted = [...requests]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final active = sorted
          .where(
            (r) =>
                r.status == REQUEST_STATUS.REQUESTING ||
                r.status == REQUEST_STATUS.PENDING_CONFIRMATION,
          )
          .firstOrNull;
      if (active != null) return active;

      return sorted
          .where(
            (r) =>
                r.status == REQUEST_STATUS.DRAFT &&
                r.inviteToken != null &&
                r.revokedAt == null &&
                r.latestStart.isAfter(DateTime.now()),
          )
          .firstOrNull;
    }

    test('ignores historical MATCHED requests even when inviteToken is present', () {
      final matchedReq = createReq(
        id: 'old-matched',
        status: REQUEST_STATUS.MATCHED,
        inviteToken: 'historical-token-123',
        createdAt: DateTime.now().subtract(const Duration(days: 7)),
      );

      final result = resolveActiveRequest([matchedReq]);
      expect(result, isNull, reason: 'MATCHED requests must never be treated as active waiting room');
    });

    test('ignores EXPIRED and CANCELLED requests even with inviteToken', () {
      final expiredReq = createReq(
        id: 'old-expired',
        status: REQUEST_STATUS.EXPIRED,
        inviteToken: 'token-exp',
      );
      final cancelledReq = createReq(
        id: 'old-cancelled',
        status: REQUEST_STATUS.CANCELLED,
        inviteToken: 'token-cancel',
      );

      final result = resolveActiveRequest([expiredReq, cancelledReq]);
      expect(result, isNull);
    });

    test('returns active REQUESTING or PENDING_CONFIRMATION request', () {
      final requestingReq = createReq(
        id: 'req-live',
        status: REQUEST_STATUS.REQUESTING,
      );
      final oldMatchedReq = createReq(
        id: 'old-matched',
        status: REQUEST_STATUS.MATCHED,
        inviteToken: 'old-tok',
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
      );

      final result = resolveActiveRequest([oldMatchedReq, requestingReq]);
      expect(result?.id, 'req-live');
    });

    test('returns active DRAFT request only when inviteToken is valid, unrevoked, and unexpired', () {
      final activeDraft = createReq(
        id: 'draft-active',
        status: REQUEST_STATUS.DRAFT,
        inviteToken: 'token-active',
        latestStart: DateTime.now().add(const Duration(hours: 1)),
      );
      final expiredDraft = createReq(
        id: 'draft-expired',
        status: REQUEST_STATUS.DRAFT,
        inviteToken: 'token-expired',
        latestStart: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final revokedDraft = createReq(
        id: 'draft-revoked',
        status: REQUEST_STATUS.DRAFT,
        inviteToken: 'token-revoked',
        revokedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        latestStart: DateTime.now().add(const Duration(hours: 1)),
      );

      expect(resolveActiveRequest([activeDraft])?.id, 'draft-active');
      expect(resolveActiveRequest([expiredDraft]), isNull);
      expect(resolveActiveRequest([revokedDraft]), isNull);
    });
  });

  group('MyActivityListItem.isOngoing', () {
    test('DRAFT request respects expiration and revocation', () {
      final now = DateTime.now();
      final validDraft = MyActivityListItem.request(
        MatchRequest(
          id: 'draft-valid',
          ownerId: 'owner',
          activityTypeId: 'act-1',
          earliestStart: now,
          latestStart: now.add(const Duration(hours: 1)),
          flexibleMinutes: 0,
          minParticipants: 2,
          maxParticipants: 4,
          allowDowngrade: false,
          status: REQUEST_STATUS.DRAFT,
          inviteToken: 'tok-1',
          createdAt: now,
          school: SCHOOL.NYCU,
          campus: '光復',
        ),
      );

      final expiredDraft = MyActivityListItem.request(
        MatchRequest(
          id: 'draft-expired',
          ownerId: 'owner',
          activityTypeId: 'act-1',
          earliestStart: now.subtract(const Duration(days: 1)),
          latestStart: now.subtract(const Duration(hours: 1)),
          flexibleMinutes: 0,
          minParticipants: 2,
          maxParticipants: 4,
          allowDowngrade: false,
          status: REQUEST_STATUS.DRAFT,
          inviteToken: 'tok-2',
          createdAt: now.subtract(const Duration(days: 1)),
          school: SCHOOL.NYCU,
          campus: '光復',
        ),
      );

      final revokedDraft = MyActivityListItem.request(
        MatchRequest(
          id: 'draft-revoked',
          ownerId: 'owner',
          activityTypeId: 'act-1',
          earliestStart: now,
          latestStart: now.add(const Duration(hours: 1)),
          flexibleMinutes: 0,
          minParticipants: 2,
          maxParticipants: 4,
          allowDowngrade: false,
          status: REQUEST_STATUS.DRAFT,
          inviteToken: 'tok-3',
          revokedAt: now.subtract(const Duration(minutes: 5)),
          createdAt: now,
          school: SCHOOL.NYCU,
          campus: '光復',
        ),
      );

      expect(validDraft.isOngoing, isTrue);
      expect(expiredDraft.isOngoing, isFalse);
      expect(revokedDraft.isOngoing, isFalse);
    });
  });
}
