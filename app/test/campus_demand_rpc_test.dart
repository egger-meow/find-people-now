import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';

void main() {
  group('CampusDemandCard deserialization & presentation', () {
    final mockJson = {
      'activity_type_id': '00000000-0000-0000-0000-000000000001',
      'activity_type_name': '羽球',
      'campus': '光復校區',
      'earliest_start': '2026-09-16T18:00:00.000Z',
      'latest_start': '2026-09-16T20:00:00.000Z',
      'sport_level': 'EASY',
      'sport_level_rating': null,
      'study_target': null,
      'min_participants': 2,
      'max_participants': 4,
      'person_count': 3,
      'request_count': 2,
    };

    test('correctly decodes json from RPC', () {
      final card = CampusDemandCard.fromJson(mockJson);
      expect(card.activityTypeId, '00000000-0000-0000-0000-000000000001');
      expect(card.activityTypeName, '羽球');
      expect(card.campus, '光復校區');
      expect(card.sportLevel, 'EASY');
      expect(card.minParticipants, 2);
      expect(card.maxParticipants, 4);
      expect(card.personCount, 3);
      expect(card.requestCount, 2);
    });

    test('generates honest signal text without misleading "差你一人"', () {
      final card = CampusDemandCard.fromJson(mockJson);
      expect(card.honestSignalText, contains('3 人'));
      expect(card.honestSignalText, isNot(contains('只差你一人')));
      expect(card.honestSignalText, isNot(contains('差你 1 人')));
      expect(card.honestSignalText, contains('球友'));
    });

    test('formats time slot label with friendly bucket prefix', () {
      final relativeNow = DateTime.utc(2026, 9, 16, 10, 0); // 18:00 UTC+8 today
      final card = CampusDemandCard(
        activityTypeId: '1',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 9, 16, 18, 0),
        latestStart: DateTime(2026, 9, 16, 20, 0),
        sportLevel: 'EASY',
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 2,
        requestCount: 1,
      );

      final label = card.timeSlotLabel(relativeTo: DateTime(2026, 9, 16, 12, 0));
      expect(label, contains('今天'));
      expect(label, contains('傍晚'));
      expect(label, contains('18:00'));
      expect(label, contains('20:00'));
      expect(label, contains('可開始'));
    });

    test('correctly filters by DemandTimeFilter', () {
      final now = DateTime(2026, 9, 16, 12, 0);
      final todayCard = CampusDemandCard(
        activityTypeId: '1',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 9, 16, 18, 0),
        latestStart: DateTime(2026, 9, 16, 20, 0),
        sportLevel: null,
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 1,
        requestCount: 1,
      );
      final tomorrowCard = CampusDemandCard(
        activityTypeId: '1',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 9, 17, 10, 0),
        latestStart: DateTime(2026, 9, 17, 12, 0),
        sportLevel: null,
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 1,
        requestCount: 1,
      );

      expect(todayCard.matchesFilter(DemandTimeFilter.all, relativeTo: now), isTrue);
      expect(todayCard.matchesFilter(DemandTimeFilter.today, relativeTo: now), isTrue);
      expect(todayCard.matchesFilter(DemandTimeFilter.tomorrow, relativeTo: now), isFalse);

      expect(tomorrowCard.matchesFilter(DemandTimeFilter.all, relativeTo: now), isTrue);
      expect(tomorrowCard.matchesFilter(DemandTimeFilter.today, relativeTo: now), isFalse);
      expect(tomorrowCard.matchesFilter(DemandTimeFilter.tomorrow, relativeTo: now), isTrue);
    });
  });
}
