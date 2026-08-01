import 'package:flutter/material.dart';

/// 活動類型沒有 icon 欄位（純文字、使用者可提案新增，見
/// SPEC §…propose_activity_type），這裡用關鍵字比對給常見類型一個圖示，比純
/// 文字卡片更有「App」感；比對不到就用通用的 [Icons.groups_rounded]，不影響
/// 任何未來新增的類型能不能選。
///
/// 共用於配對表單（選類型步驟）跟「我的活動」清單（辨識同一個活動類型）——
/// 兩處使用同一組圖示才有辨識一致性，原本各自維護一份容易在新增類型時漏改
/// 其中一邊。
IconData activityTypeIcon(String name) {
  final n = name.toLowerCase();
  const table = <String, IconData>{
    '籃球': Icons.sports_basketball_rounded,
    '排球': Icons.sports_volleyball_rounded,
    '羽球': Icons.sports_tennis_rounded,
    '網球': Icons.sports_tennis_rounded,
    '桌球': Icons.sports_tennis_rounded,
    '足球': Icons.sports_soccer_rounded,
    '棒球': Icons.sports_baseball_rounded,
    '咖啡': Icons.local_cafe_rounded,
    '散步': Icons.directions_walk_rounded,
    '慢跑': Icons.directions_run_rounded,
    '跑步': Icons.directions_run_rounded,
    '讀書': Icons.menu_book_rounded,
    '唸書': Icons.menu_book_rounded,
    '自習': Icons.menu_book_rounded,
    '健身': Icons.fitness_center_rounded,
    '重訓': Icons.fitness_center_rounded,
    '桌遊': Icons.casino_rounded,
    '遊戲': Icons.sports_esports_rounded,
    '電影': Icons.movie_rounded,
    '唱歌': Icons.mic_rounded,
    'ktv': Icons.mic_rounded,
    '腳踏車': Icons.directions_bike_rounded,
    '單車': Icons.directions_bike_rounded,
    '吃飯': Icons.restaurant_rounded,
    '晚餐': Icons.restaurant_rounded,
    '午餐': Icons.restaurant_rounded,
    '早餐': Icons.free_breakfast_rounded,
    '逛街': Icons.storefront_rounded,
    '爬山': Icons.terrain_rounded,
    '游泳': Icons.pool_rounded,
  };
  for (final entry in table.entries) {
    if (n.contains(entry.key)) return entry.value;
  }
  return Icons.groups_rounded;
}
