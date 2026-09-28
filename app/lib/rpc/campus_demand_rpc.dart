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
  final int? maxParticipants;
  final int personCount;
  final int requestCount;
  final int formedGroupCount;
  final int formedPersonCount;

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
    this.maxParticipants,
    required this.personCount,
    required this.requestCount,
    this.formedGroupCount = 0,
    this.formedPersonCount = 0,
  });

  factory CampusDemandCard.fromJson(Map<String, dynamic> json) {
    final waitingPerson = (json['waiting_person_count'] as int?) ??
        (json['person_count'] as int? ?? 0);
    final waitingRequest = (json['waiting_request_count'] as int?) ??
        (json['request_count'] as int? ?? 0);
    final formedGroup = (json['formed_group_count'] as int?) ?? 0;
    final formedPerson = (json['formed_person_count'] as int?) ?? 0;

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
      maxParticipants: (json['max_participants'] as num?)?.toInt(),
      personCount: waitingPerson,
      requestCount: waitingRequest,
      formedGroupCount: formedGroup,
      formedPersonCount: formedPerson,
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
    final endDate = DateTime(
      latestStart.year,
      latestStart.month,
      latestStart.day,
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

    final endDayDiff = endDate.difference(today).inDays;
    String endDatePrefix;
    if (endDayDiff == 0) {
      endDatePrefix = '今天';
    } else if (endDayDiff == 1) {
      endDatePrefix = '明天';
    } else if (endDayDiff == 2) {
      endDatePrefix = '後天';
    } else {
      endDatePrefix = '${latestStart.month}月${latestStart.day}日';
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

    final isCrossDay = !startDate.isAtSameMomentAs(endDate);
    final endFormatted = isCrossDay
        ? '$endDatePrefix ${_formatTime(latestStart)}'
        : _formatTime(latestStart);

    // Check if it's "now" (starts within 30 min and already or about to start)
    final diffMinutes = earliestStart.difference(now).inMinutes;
    if (diffMinutes >= -15 && diffMinutes <= 15 && latestStart.difference(earliestStart).inMinutes <= 45) {
      return '現在 ${_formatTime(earliestStart)}–$endFormatted 可開始';
    }

    return '$datePrefix$bucketName ${_formatTime(earliestStart)}–$endFormatted 可開始';
  }

  String get waitingSignalText {
    final isBallSport = ['羽球', '籃球', '網球', '桌球', '排球'].contains(activityTypeName);
    final role = isBallSport ? '球友' : (activityTypeName == '讀書' ? '讀書夥伴' : '夥伴');

    if (requestCount > 1) {
      return '這個時段有 $personCount 人在找$role（共 $requestCount 組需求等待相容）';
    }
    return '這個時段有 $personCount 人在找$role';
  }

  String get formedSignalText {
    if (formedPersonCount > 0) {
      if (formedGroupCount > 1) {
        return '今日已成團 $formedPersonCount 人（$formedGroupCount 組）';
      }
      return '今日已成團 $formedPersonCount 人';
    }
    return '今日尚無已成團';
  }

  String get honestSignalText {
    final waiting = waitingSignalText;
    if (formedPersonCount > 0) {
      return '$waiting · $formedSignalText';
    }
    return '$waiting · 成團依條件撮合';
  }

  String get headcountRangeLabel =>
      maxParticipants != null
          ? '最少 $minParticipants 人，最多 $maxParticipants 人'
          : '最少 $minParticipants 人';

  bool matchesFilter(DemandTimeFilter filter, {DateTime? relativeTo}) {
    final now = relativeTo ?? DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
    final tomorrowStart = todayStart.add(const Duration(days: 1));
    final tomorrowEnd = DateTime(
      tomorrowStart.year,
      tomorrowStart.month,
      tomorrowStart.day,
      23,
      59,
      59,
      999,
    );

    switch (filter) {
      case DemandTimeFilter.all:
        return true;
      case DemandTimeFilter.now:
        return earliestStart.isBefore(now.add(const Duration(minutes: 30))) &&
            latestStart.isAfter(now);
      case DemandTimeFilter.today:
        return !earliestStart.isAfter(todayEnd) &&
            !latestStart.isBefore(todayStart) &&
            latestStart.isAfter(now);
      case DemandTimeFilter.tomorrow:
        return !earliestStart.isAfter(tomorrowEnd) &&
            !latestStart.isBefore(tomorrowStart);
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

/// 匿名公開探索活動需求結果物件
class PublicCampusDemandsResult {
  final List<CampusDemandCard> demands;
  final List<String> campuses;
  final bool hasSuppressedDemands;

  const PublicCampusDemandsResult({
    required this.demands,
    required this.campuses,
    required this.hasSuppressedDemands,
  });

  factory PublicCampusDemandsResult.fromJson(Map<String, dynamic> json) {
    final demandsList = (json['demands'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(CampusDemandCard.fromJson)
        .toList();
    final campusesList = (json['campuses'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final hasSuppressed = json['has_suppressed_demands'] as bool? ?? false;

    return PublicCampusDemandsResult(
      demands: demandsList,
      campuses: campusesList,
      hasSuppressedDemands: hasSuppressed,
    );
  }
}

/// 未登入訪客專用粗粒度、唯讀探索 RPC：`rpc: get_public_campus_demands(school, campus)`
Future<PublicCampusDemandsResult> getPublicCampusDemands(
  SupabaseClient client, {
  required SCHOOL school,
  String? campus,
}) {
  return callRpc<PublicCampusDemandsResult>(
    client,
    'get_public_campus_demands',
    params: {
      'p_school': school.name,
      if (campus != null && campus.isNotEmpty) 'p_campus': campus,
    },
    decode: (data) => PublicCampusDemandsResult.fromJson(
      data as Map<String, dynamic>,
    ),
  );
}

/// 依 stable `activityTypeId` 聚合的探索需求群組（UI_PLAN / iOS UX 指南 §7）
class AggregatedDemandGroup {
  final String activityTypeId;
  final String activityTypeName;
  final String campus;
  final List<CampusDemandCard> demands;

  const AggregatedDemandGroup({
    required this.activityTypeId,
    required this.activityTypeName,
    required this.campus,
    required this.demands,
  });

  bool get hasSingleDemand => demands.length == 1;

  int get totalRequests =>
      demands.fold<int>(0, (sum, d) => sum + d.requestCount);

  int get singlePersonCount =>
      hasSingleDemand ? demands.first.personCount : 0;

  String summaryHeadline(DemandTimeFilter filter, {DateTime? relativeNow}) {
    final prefix = _filterPrefix(filter, relativeNow: relativeNow);
    if (hasSingleDemand) {
      return '$prefix $singlePersonCount 人在揪$activityTypeName';
    }
    return '$prefix $totalRequests 組需求在揪$activityTypeName';
  }

  String _filterPrefix(DemandTimeFilter filter, {DateTime? relativeNow}) {
    switch (filter) {
      case DemandTimeFilter.now:
        return '現在';
      case DemandTimeFilter.today:
        return '今天';
      case DemandTimeFilter.tomorrow:
        return '明天';
      case DemandTimeFilter.all:
        final now = relativeNow ?? DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final allToday = demands.every((d) {
          final start = d.earliestStart;
          return start.year == today.year &&
              start.month == today.month &&
              start.day == today.day;
        });
        if (allToday) return '今天';
        final tomorrow = today.add(const Duration(days: 1));
        final allTomorrow = demands.every((d) {
          final start = d.earliestStart;
          return start.year == tomorrow.year &&
              start.month == tomorrow.month &&
              start.day == tomorrow.day;
        });
        if (allTomorrow) return '明天';
        return '近期';
    }
  }
}

/// 將經時間篩選後的需求依 stable `activityTypeId` 聚合成群組。
List<AggregatedDemandGroup> aggregateDemands(List<CampusDemandCard> demands) {
  final Map<String, List<CampusDemandCard>> grouped = {};
  for (final d in demands) {
    grouped.putIfAbsent(d.activityTypeId, () => []).add(d);
  }
  return grouped.entries
      .map((e) => AggregatedDemandGroup(
            activityTypeId: e.key,
            activityTypeName: e.value.first.activityTypeName,
            campus: e.value.first.campus,
            demands: e.value,
          ))
      .toList();
}
