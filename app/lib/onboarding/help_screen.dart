import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_card.dart';

/// UI_PLAN.md §11.2 常駐說明入口——比 Onboarding（onboarding_overlay.dart）
/// 詳細、對應實際畫面的分步驟圖文說明，服務兩種情境：①用到一半忘記目前
/// 階段該做什麼；②透過邀請連結加入、未必看過完整登入流程/Onboarding 的新
/// 使用者。放在「我的」頁面跟首頁（配對頁）AppBar 右上角的說明圖示，兩處
/// 都連到同一個畫面。
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _steps = [
    (
      Icons.edit_calendar_rounded,
      '1. 發起配對',
      '在「首頁」選活動類型、校區、想約的人數，決定人數不夠時要不要接受少一點人也算成局，送出後進入「等待室」。已經有朋友的邀請碼了嗎？可以不用自己發起，直接點首頁右上角的連結圖示輸入邀請碼，馬上加入他的房間。',
    ),
    (
      Icons.group_add_rounded,
      '2. 等待室',
      '可以按「邀請朋友」把邀請碼分享給朋友一起加入，或什麼都不做，讓系統在時間內自動幫你配對到人。等待室會即時反應狀態變化，不用自己重新整理。',
    ),
    (
      Icons.verified_user_rounded,
      '3. 小人數安全確認',
      '如果這次配對只湊到少少幾個人，系統會先讓雙方看對方的基本資料卡（不含聯絡方式）並各自確認「要參加」才會真的成團——避免陌生的兩人單獨活動在完全沒有把關的狀況下發生。',
    ),
    (
      Icons.celebration_rounded,
      '4. 配對成功',
      '成團後可以在「我的活動」找到這個活動，進去後有「地點」跟「成員」兩個分頁：地點分頁大家一起投票決定活動地點——投票結果全體成員即時都看得到目前領先的候選，且隨時能改票，不是投完就鎖死；成員分頁填集合地點跟給隊友看的見面提示、看到隊友資料與聯絡方式，也能在這裡封鎖或檢舉。',
    ),
    (
      Icons.near_me_rounded,
      '5. 到了現場',
      '抵達集合地點後，到「成員」分頁點自己卡片上的「我到了」，其他隊友會立刻收到通知；同組成員也能在這裡看到誰已經到了，方便判斷要不要先開始。這個動作送出後無法收回，按之前系統會再跟你確認一次。',
    ),
    (
      Icons.task_alt_rounded,
      '6. 活動結束',
      '活動時間到了之後，花 10 秒回報這次順不順利。如果覺得跟某些隊友合拍，可以按「再約」——雙方都按了才會永久保留彼此的聯絡方式。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('使用說明')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            for (final (icon, title, body) in _steps) ...[
              AppCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: AppSpacing.xs),
                          Text(body, style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}
