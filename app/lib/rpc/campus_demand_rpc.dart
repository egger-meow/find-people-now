import 'package:supabase_flutter/supabase_flutter.dart';

import '../generated/supadart_header.dart' show SCHOOL;
import 'rpc_client.dart';

enum DemandTimeFilter {
  all('全部'),
  now('現在'),
  today('今天'),
  tomorrow('明天');

  final String label;
  const DemandTimeFilter(this.label);
}

class CampusDemandCard {
  final String activityTypeId;
  final String activityTypeName;
  final String campus;
  final DateTime earliestStart;
  final DateTime latestStart;
  final String? sportLevel;
  final int? sportLevelRating;
  final String? studyTarget;
  final int minParticipants;
  final int maxParticipants;
  final int personCount;
  final int requestCount;

  const CampusDemandCard({
    required this.activityTypeId,
    required this.activityTypeName,
    required this.campus,
    required this.earliestStart,
    required this.latestStart,
    this.sportLevel,
    this.sportLevelRating,
    this.studyTarget,
    required this.minParticipants,
    required this.maxParticipants,
    required this.personCount,
    required this.requestCount,
  });

  factory CampusDemandCard.fromJson(Map<String, dynamic> json) {
    return CampusDemandCard(
      activityTypeId: json['activity_type_id'] as String,
      activityTypeName: json['activity_type_name'] as String,
      campus: json['campus'] as String,
      earliestStart: DateTime.parse(json['earliest_start'] as String).toLocal(),
      latestStart: DateTime.parse(json['latest_start'] as String).toLocal(),
      sportLevel: json['sport_level'] as String?,
      sportLevelRating: json['sport_level_rating'] as int?,
      studyTarget: json['study_target'] as String?,
      minParticipants: json['min_participants'] as int,
      maxParticipants: json['max_participants'] as int,
      personCount: json['person_count'] as int,
      requestCount: json['request_count'] as int,
    );
  }

  static String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String timeSlotLabel({DateTime? relativeTo}) {
    final now = relativeTo ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDate = DateTime(
      earliestStart.year,
      earliestStart.month,
      earliestStart.day,
    );
    final dayDiff = startDate.difference(today).inDays;

    String datePrefix;
    if (dayDiff == 0) {
      datePrefix = '今天';
    } else if (dayDiff == 1) {
      datePrefix = '明天';
    } else {
      datePrefix = '${earliestStart.month}月${earliestStart.day}日';
    }

    final hour = earliestStart.hour;
    String bucketName;
    if (hour >= 6 && hour < 12) {
      bucketName = '早上';
    } else if (hour >= 12 && hour < 14) {
      bucketName = '中午';
    } else if (hour >= 14 && hour < 18) {
      bucketName = '下午';
    } else if (hour >= 18 && hour < 20) {
      bucketName = '傍晚';
    } else {
      bucketName = '晚上';
    }

    // Check if it's "now" (starts within 30 min and already or about to start)
    final diffMinutes = earliestStart.difference(now).inMinutes;
    if (diffMinutes >= -15 && diffMinutes <= 15 && latestStart.difference(earliestStart).inMinutes <= 45) {
      return '現在 ${_formatTime(earliestStart)}–${_formatTime(latestStart)} 可開始';
    }

    return '$datePrefix$bucketName ${_formatTime(earliestStart)}–${_formatTime(latestStart)} 可開始';
  }

  String get honestSignalText {
    final isBallSport = ['羽球', '籃球', '網球', '桌球', '排球'].contains(activityTypeName);
    final role = isBallSport ? '球友' : (activityTypeName == '讀書' ? '讀書夥伴' : '夥伴');

    if (requestCount > 1) {
      return '這個時段有 $personCount 人在找$role（共 $requestCount 組需求等待相容）';
    }
    return '這個時段有 $personCount 人在找$role';
  }

  String get headcountRangeLabel => '最少 $minParticipants 人，最多 $maxParticipants 人';

  bool matchesFilter(DemandTimeFilter filter, {DateTime? relativeTo}) {
    final now = relativeTo ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final startDate = DateTime(
      earliestStart.year,
      earliestStart.month,
      earliestStart.day,
    );

    switch (filter) {
      case DemandTimeFilter.all:
        return true;
      case DemandTimeFilter.now:
        return earliestStart.isBefore(now.add(const Duration(minutes: 30))) &&
            latestStart.isAfter(now);
      case DemandTimeFilter.today:
        return startDate.isAtSameMomentAs(today);
      case DemandTimeFilter.tomorrow:
        return startDate.isAtSameMomentAs(tomorrow);
    }
  }
}

/// docs/API.md §13.2 — `rpc: get_campus_demands(school, campus)` (v1.43).
Future<List<CampusDemandCard>> getCampusDemands(
  SupabaseClient client, {
  required SCHOOL school,
  required String campus,
}) {
  return callRpc<List<CampusDemandCard>>(
    client,
    'get_campus_demands',
    params: {'p_school': school.name, 'p_campus': campus},
    decode: (data) => (data as List)
        .cast<Map<String, dynamic>>()
        .map(CampusDemandCard.fromJson)
        .toList(),
  );
}
