import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_card.dart';

/// UI_PLAN.md §8.2 反饋/QA 頁面內容（定案版）——純靜態文字頁，逐字對應該節
/// 文案，聯絡信箱維持文件裡本來就標記的〔待補〕狀態
/// （見 docs/TERMS_OF_SERVICE.md／docs/PRIVACY_POLICY.md 同樣的 🔴 標記），
/// 不在這裡自己編一個看起來像真的信箱。
class FeedbackScreen extends StatelessWidget {
  const FeedbackScreen({super.key});

  static const _entries = [
    (
      '為什麼沒有性別篩選？',
      '這個 App 的核心理念是「找一起做事的人」，不是交友或約會軟體。我們刻意不讓性別成為配對條件，'
          '避免整個產品氣氛變成在配對象。你填的性別只會顯示在個人資料上，讓其他成員認識你，完全不會拿來篩選或決定要不要把你配給誰。\n\n'
          '話雖如此，我們知道有些活動（例如夜間散步、單獨兩人的場合）確實有人會希望能限定同性別的夥伴，這是我們正在評估的方向（v2），'
          '如果你有這方面的需求或想法，歡迎透過下方信箱告訴我們。',
    ),
    ('配對成功後，我要怎麼跟其他人聯繫？', '平台不提供站內聊天，透過對方公開的 IG/LINE/Discord 聯繫。'),
    ('活動可以選科目/程度嗎（Matching Attributes）？', 'v2 評估中，視「讀書」等類型實際使用量決定，歡迎透過信箱回饋需求。'),
    ('可以跨學校配對嗎？', '目前僅限同校（NYCU/NTHU 各自獨立），跨校功能評估中。'),
    (
      '這個 App 安全嗎？',
      '安全性是我們最在意的事情之一，目前有這幾層機制：\n\n'
          '• 身份驗證：只有 @nycu.edu.tw／@nthu.edu.tw 的學校信箱能註冊，確保你遇到的都是（曾經是）本校學生\n'
          '• 盲配不挑人：配對成立前，系統不會讓任何人看到候選對象的個人資料，也不會有人能「挑」你或被你挑，降低被特定對象鎖定的風險\n'
          '• 可信度制度：每個人依出席紀錄有 Trusted／Normal／New 三個等級，全新帳號無法直接參加只有兩人的活動，'
          '必須先完成過一次團體活動才能解鎖，避免陌生新帳號直接約你單獨見面\n'
          '• 停權機制：連續多次放鳥（約好不出現）會被暫時停權\n'
          '• 封鎖功能：如果遇到讓你不舒服的人，可以直接封鎖對方，之後系統不會再把你們配在一起，對方不會收到任何通知\n'
          '• 帳號刪除：你可以隨時在「我的」頁面刪除帳號跟所有個人資料\n\n'
          '我們無法做到絕對零風險——任何讓陌生人見面的服務都一樣——但這些機制的設計目標，就是把風險降到最低，'
          '並且讓你在感覺不對勁的第一時間，有實際能保護自己的工具，而不是只能默默忍受。',
    ),
    ('怎麼確認大家都是在校學生？', '學校信箱驗證能確保曾是本校學生，但無法排除已畢業校友（部分學校畢業生信箱長期有效）；未來若能與校方系統整合會優先加上。'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('反饋 / 常見問答')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            for (final (question, answer) in _entries) ...[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(question, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    Text(answer, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('聯絡信箱', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  Text('〔聯絡信箱待補〕', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
