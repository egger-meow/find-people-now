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
      final relativeNow = DateTime(2026, 9, 16, 12, 0);
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

      final label = card.timeSlotLabel(relativeTo: relativeNow);
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

    test('formats cross-day time slot label with explicit next day prefix', () {
      final crossDayCard = CampusDemandCard(
        activityTypeId: '1',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 9, 16, 23, 0),
        latestStart: DateTime(2026, 9, 17, 1, 0),
        sportLevel: null,
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 1,
        requestCount: 1,
      );

      final label = crossDayCard.timeSlotLabel(relativeTo: DateTime(2026, 9, 16, 20, 0));
      expect(label, equals('今天晚上 23:00–明天 01:00 可開始'));
    });

    test('cross-day demand matches both today and tomorrow filters when overlapping', () {
      final crossDayCard = CampusDemandCard(
        activityTypeId: '1',
        activityTypeName: '羽球',
        campus: '光復校區',
        earliestStart: DateTime(2026, 9, 16, 23, 0),
        latestStart: DateTime(2026, 9, 17, 1, 0),
        sportLevel: null,
        sportLevelRating: null,
        studyTarget: null,
        minParticipants: 2,
        maxParticipants: 4,
        personCount: 1,
        requestCount: 1,
      );

      // 1. 今天 22:00（跨日需求尚未開始）：在「今天」與「明天」篩選皆應出現
      final beforeMidnight = DateTime(2026, 9, 16, 22, 0);
      expect(crossDayCard.matchesFilter(DemandTimeFilter.today, relativeTo: beforeMidnight), isTrue);
      expect(crossDayCard.matchesFilter(DemandTimeFilter.tomorrow, relativeTo: beforeMidnight), isTrue);

      // 2. 過午夜 00:30（處於跨日區間中）：在當天（9/17）「今天」篩選仍有效可見
      final afterMidnight = DateTime(2026, 9, 17, 0, 30);
      expect(crossDayCard.matchesFilter(DemandTimeFilter.today, relativeTo: afterMidnight), isTrue);

      // 3. 01:30（已過 latestStart 01:00）：已過期，不再出現在「今天」
      final afterEnd = DateTime(2026, 9, 17, 1, 30);
      expect(crossDayCard.matchesFilter(DemandTimeFilter.today, relativeTo: afterEnd), isFalse);
    });

    test('correctly handles nullable max_participants for open-ended groups', () {
      final openEndedJson = {
        'activity_type_id': '00000000-0000-0000-0000-000000000002',
        'activity_type_name': '慢跑',
        'campus': '光復校區',
        'earliest_start': '2026-09-16T18:00:00.000Z',
        'latest_start': '2026-09-16T20:00:00.000Z',
        'sport_level': null,
        'sport_level_rating': null,
        'study_target': null,
        'min_participants': 2,
        'max_participants': null,
        'person_count': 2,
        'request_count': 1,
      };

      final card = CampusDemandCard.fromJson(openEndedJson);
      expect(card.minParticipants, 2);
      expect(card.maxParticipants, isNull);
      expect(card.headcountRangeLabel, '最少 2 人');

      final boundedCard = CampusDemandCard(
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
        personCount: 2,
        requestCount: 1,
      );
      expect(boundedCard.headcountRangeLabel, '最少 2 人，最多 4 人');
    });
  });
}
