import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io' show Platform;

import '../auth/auth_providers.dart';
import '../rpc/api_exception.dart';
import '../rpc/feedback_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';

/// UI_PLAN.md §8.2 反饋/QA 頁面內容（定案版）＋ v1.25 新增的送出表單——先前
/// 這裡是純靜態 FAQ 頁，「聯絡信箱」欄位一直卡在〔待補〕（沒有真的信箱可
/// 填）。v1.25 不是去補一個信箱地址，而是直接把「送出」這個動作做成表單：
/// `submit_feedback` RPC 先把訊息寫進 `feedback` 表（唯一保證存在的持久
/// 記錄），再盡力呼叫 `send-feedback-email` Edge Function 寄信通知——寄信
/// 失敗不影響「已送出」的使用者體驗，見兩者各自的檔頭註解。
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
    // 反饋：「反饋填入還在最下面」——原本把送出表單擺在整串 FAQ 長文之後，
    // 使用者點進這頁多半是想直接送反饋，卻要先滑過所有 FAQ 才看得到欄位。
    // 改成表單放最上面（主要動作優先），FAQ 收進可展開的清單、預設收合，
    // 不再是一長串攤開的文字牆。
    return Scaffold(
      appBar: AppBar(title: const Text('反饋 / 常見問答')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            const _FeedbackForm(),
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                '常見問題',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < _entries.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _FaqTile(question: _entries[i].$1, answer: _entries[i].$2),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaqTile extends StatelessWidget {
  const _FaqTile({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
      title: Text(question, style: Theme.of(context).textTheme.titleSmall),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(answer, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _FeedbackForm extends ConsumerStatefulWidget {
  const _FeedbackForm();

  @override
  ConsumerState<_FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends ConsumerState<_FeedbackForm> {
  final _controller = TextEditingController();
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _controller.text.trim();
    if (message.isEmpty) {
      setState(() => _error = '請輸入回饋內容');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });

    final client = ref.read(supabaseClientProvider);
    try {
      // 這兩項只是客服排查用的輔助資訊，任何一項拿不到都不該擋住送出——
      // 見 send-feedback-email 的 email 內文用 '-' 顯示缺漏欄位。
      String? appVersion;
      try {
        final info = await PackageInfo.fromPlatform();
        appVersion = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // ignore
      }
      final deviceInfo = Platform.operatingSystem;

      final feedback = await submitFeedback(
        client,
        message: message,
        appVersion: appVersion,
        deviceInfo: deviceInfo,
      );
      await sendFeedbackEmail(client, feedbackId: feedback.id);

      if (!mounted) return;
      _controller.clear();
      setState(() => _sent = true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗：${e.code.name}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗，請檢查網路連線後再試一次');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('送出意見回饋', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '有 bug、建議或想稱讚我們一下都歡迎，會直接送到開發者信箱。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(controller: _controller, label: '你想說的話', maxLines: 4),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_sent) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.primary, size: 18),
                const SizedBox(width: AppSpacing.xs),
                const Text('已收到你的回饋，謝謝！'),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: '送出', loading: _sending, onPressed: _submit),
        ],
      ),
    );
  }
}
