import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../account_deletion.dart';
import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../generated/app_user.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL;
import '../match/match_providers.dart' show myAppUserProvider, myBadgesProvider, myReliabilityProvider;
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart' show AchievementBadge, ReliabilityTier;
import '../theme/app_theme.dart';
import '../theme/theme_providers.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/loading_indicator.dart';

String _themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => '跟隨系統',
      ThemeMode.light => '亮色',
      ThemeMode.dark => '暗色',
    };

String _degreeLabel(DEGREE_LEVEL level) => switch (level) {
      DEGREE_LEVEL.UNDERGRAD => '大學部',
      DEGREE_LEVEL.MASTER => '碩士班',
      DEGREE_LEVEL.PHD => '博士班',
    };

String _tierLabel(ReliabilityTier tier) => switch (tier) {
      ReliabilityTier.trusted => 'Trusted',
      ReliabilityTier.normal => 'Normal',
      ReliabilityTier.newUser => 'New',
      ReliabilityTier.unknown => '—',
    };

Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
  final confirmed = await showAppConfirmDialog(
    context,
    title: '登出？',
    message: '登出後需要重新驗證信箱才能再次登入。',
    confirmLabel: '登出',
  );
  if (!confirmed) return;
  // authStateProvider 會觸發 router 的 refreshListenable 自動導回 /login
  // （見 app_router.dart 開頭註解、_DeleteAccountSectionState._delete 的同款用法），
  // 這裡不需要、也不應該手動導覽。
  await ref.read(supabaseClientProvider).auth.signOut();
}

/// 分區標題——反饋 v2：原本 6 個各自獨立的 [AppCard] 疊在一起「太像後台表單」，
/// 改成幾個有標題的分組，同組內容用 [Divider] 隔開、共用一個 [AppCard]。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Achievement Badges（v1.29）——獎勵性質，補充（不取代）上方的可信度等級
/// 卡片。已達成的徽章亮色顯示；未達成的用低透明度顯示（可以看到「還差什麼」，
/// 但不喧賓奪主）。載入失敗/中安靜收合，不影響頁面其餘部分。
class _BadgesSection extends ConsumerWidget {
  const _BadgesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badgesAsync = ref.watch(myBadgesProvider);
    return badgesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => const SizedBox.shrink(),
      data: (earned) => AppCard(
        child: Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final badge in AchievementBadge.values)
              Opacity(
                opacity: earned.contains(badge) ? 1.0 : 0.35,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(badge.icon, style: const TextStyle(fontSize: 22)),
                    Text(badge.label, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// UI_PLAN.md §8.1「我的」——個人資料卡（可編輯，見 edit_profile_screen.dart）、
/// 可信度徽章、聯絡方式、帳號刪除入口（Apple/Google 上架硬性規定，位置需明顯
/// 好找）、反饋/QA 連結、常駐說明入口（§11.2）、登出。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(myAppUserProvider);
    final reliabilityAsync = ref.watch(myReliabilityProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('帳戶'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded),
            tooltip: '使用說明',
            onPressed: () => context.push('/help'),
          ),
        ],
      ),
      body: SafeArea(
        child: userAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('載入失敗：$error')),
          data: (user) {
            if (user == null) return const LoadingIndicator();
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(myAppUserProvider);
                ref.invalidate(myReliabilityProvider);
              },
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  _ProfileHeaderCard(user: user),
                  const SizedBox(height: AppSpacing.sm),
                  reliabilityAsync.when(
                    loading: () => const SizedBox.shrink(),
                    error: (error, stack) => const SizedBox.shrink(),
                    data: (reliability) => AppCard(
                      child: Row(
                        children: [
                          Icon(Icons.verified_rounded, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: AppSpacing.sm),
                          Text('可信度等級：${_tierLabel(reliability.tier)}',
                              style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const _BadgesSection(),
                  const SizedBox(height: AppSpacing.lg),
                  const _SectionLabel('設定'),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(AppSpacing.md),
                          child: _ThemeModeSection(),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: _MoreInfoSection(user: user),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: _ContactsSection(user: user),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const _SectionLabel('說明與回饋'),
                  AppCard(
                    padding: EdgeInsets.zero,
                    // AppCard 沒帶 onTap 時只有 Container/DecoratedBox，沒有
                    // Material 祖先給裡面的 ListTile 畫 ink splash——自己補一層
                    // 透明 Material。
                    child: Material(
                      type: MaterialType.transparency,
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.question_answer_outlined),
                            title: const Text('反饋 / 常見問答'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => context.push('/profile/feedback'),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.menu_book_outlined),
                            title: const Text('使用說明'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => context.push('/help'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        leading: const Icon(Icons.logout_rounded),
                        title: const Text('登出'),
                        onTap: () => _confirmSignOut(context, ref),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _DeleteAccountSection(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProfileHeaderCard extends StatelessWidget {
  const _ProfileHeaderCard({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundImage: user.avatarUrl.isEmpty ? null : NetworkImage(user.avatarUrl),
            child: user.avatarUrl.isEmpty ? const Icon(Icons.person_rounded, size: 32) : null,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.displayName, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${schoolLabel(user.school)} · ${user.department ?? '未填科系'} · ${_degreeLabel(user.degreeLevel)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '編輯個人資料',
            onPressed: () => context.push('/profile/edit'),
          ),
        ],
      ),
    );
  }
}

/// 性別欄位刻意折疊在這裡，不與頭像/名字平起平坐（UI_PLAN §8.1）。
/// 反饋 v2：不再自己包一層 [AppCard]——現在跟其他「設定」子項共用外層一個
/// 卡片、用 [Divider] 分隔，減少畫面上一堆獨立色塊的感覺。
class _MoreInfoSection extends StatefulWidget {
  const _MoreInfoSection({required this.user});

  final AppUser user;

  @override
  State<_MoreInfoSection> createState() => _MoreInfoSectionState();
}

class _MoreInfoSectionState extends State<_MoreInfoSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('更多資料', style: Theme.of(context).textTheme.titleSmall),
              Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('性別：${widget.user.gender ?? '未填（僅供展示，不影響配對）'}',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.xs),
            Text('自我介紹：${widget.user.bio.isNotEmpty ? widget.user.bio : '還沒有寫自我介紹'}',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _ContactsSection extends StatelessWidget {
  const _ContactsSection({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (user.contactIg?.isNotEmpty == true) 'IG: ${user.contactIg}',
      if (user.contactLine?.isNotEmpty == true) 'LINE: ${user.contactLine}',
      if (user.contactDiscord?.isNotEmpty == true) 'Discord: ${user.contactDiscord}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('聯絡方式', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        if (lines.isEmpty)
          const Text('還沒有留下任何聯絡方式')
        else
          for (final line in lines) Text(line, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

/// 反饋：「我的資訊頁 要加 白/暗 模式(預設一樣跟系統)」。
class _ThemeModeSection extends ConsumerWidget {
  const _ThemeModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('外觀', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<ThemeMode>(
          segments: [
            for (final m in ThemeMode.values)
              ButtonSegment(value: m, label: Text(_themeModeLabel(m))),
          ],
          selected: {mode},
          onSelectionChanged: (selected) =>
              ref.read(themeModeProvider.notifier).setThemeMode(selected.first),
        ),
      ],
    );
  }
}

/// 帳號刪除入口——UI_PLAN §8.1 要求「位置需明顯好找」（Apple/Google 上架硬性
/// 規定），這裡放在「我的」頁面最下方、視覺上跟其餘設定項目分開的危險區塊，
/// 而不是藏進另一層選單，符合「好找」但仍跟一般操作有明顯區隔。
class _DeleteAccountSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_DeleteAccountSection> createState() => _DeleteAccountSectionState();
}

class _DeleteAccountSectionState extends ConsumerState<_DeleteAccountSection> {
  bool _busy = false;
  String? _error;

  Future<bool> _confirm() {
    return showAppConfirmDialog(
      context,
      title: '刪除帳號？',
      message: '這個動作無法復原：你的個人資料會被清除，進行中的配對／活動會自動退出或取消，歷史紀錄裡的其他人不會受影響。',
      confirmLabel: '刪除帳號',
      isDestructive: true,
    );
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      await deleteAccountFlow(client, confirm: _confirm);
      // 成功後 client.auth.signOut() 會觸發 authStateProvider，router 的
      // refreshListenable 自動導回 /login（見 app_router.dart 開頭註解），
      // 這裡不需要、也不應該手動導覽。
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '刪除失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('危險區域', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '刪除帳號會清除你的個人資料，且無法復原。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(color: Theme.of(context).colorScheme.error),
            ),
            onPressed: _busy ? null : _delete,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : const Text('刪除帳號'),
          ),
        ],
      ),
    );
  }
}
