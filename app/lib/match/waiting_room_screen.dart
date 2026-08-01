import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../generated/match_request.dart';
import '../generated/supadart_header.dart' show REQUEST_MEMBER_ROLE, REQUEST_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/countdown_text.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';

/// UI_PLAN.md §3 等待室——技術要求明講必須用 Supabase Realtime 訂閱
/// `match_request` 狀態變化，不能只靠靜態載入或使用者手動刷新。這裡同時訂閱
/// `request_member`（成員人數變化）與 `match_request`（狀態變化）兩條 Realtime
/// stream（見 lib/match/match_providers.dart）。
///
/// 成員頭像列刻意匿名（見 match_providers.dart 的 [requestMembersStreamProvider]
/// 註解）——目前 RLS 只讓 `app_user` 查自己的資料（own_profile_select），配對
/// 成立前顯示其他成員的真實大頭貼/姓名沒有資料來源，也違背「盲配不挑人」的
/// 既有設計精神（UI_PLAN §8.2 FAQ Q5）。
class WaitingRoomScreen extends ConsumerStatefulWidget {
  const WaitingRoomScreen({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<WaitingRoomScreen> createState() => _WaitingRoomScreenState();
}

class _WaitingRoomScreenState extends ConsumerState<WaitingRoomScreen> {
  String? _inviteToken;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final requestAsync = ref.watch(matchRequestStreamProvider(widget.requestId));
    final membersAsync = ref.watch(requestMembersStreamProvider(widget.requestId));
    final userId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('等待室')),
      body: SafeArea(
        child: requestAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('連線失敗：$error')),
          data: (request) {
            if (request == null) {
              return const Center(child: Text('找不到這個配對，可能已經被取消了'));
            }
            if (isTerminalForWaitingRoom(request.status)) {
              return _TransitionedState(status: request.status);
            }

            return membersAsync.when(
              loading: () => const LoadingIndicator(),
              error: (error, stack) => Center(child: Text('連線失敗：$error')),
              data: (members) {
                final isOwner = members.any(
                  (m) => m.userId == userId && m.role == REQUEST_MEMBER_ROLE.OWNER,
                );
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    _CountdownHeroCard(deadline: request.latestStart),
                    const SizedBox(height: AppSpacing.md),
                    _RequestInfoCard(request: request),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '目前房間成員（${members.length} / ${request.minParticipants} 人成立）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        for (final member in members)
                          _AnonymousAvatar(
                            key: ValueKey(member.id),
                            isSelf: member.userId == userId,
                            isOwner: member.role == REQUEST_MEMBER_ROLE.OWNER,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (_inviteToken == null)
                      AppButton(
                        label: '邀請朋友',
                        loading: _busy,
                        onPressed: () => _getOrCreateInviteLink(request.id),
                      )
                    else
                      AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '邀請碼（分享給朋友）',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                              ),
                              child: SelectableText(
                                _inviteToken!,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontFamily: 'monospace',
                                      letterSpacing: 1.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: _inviteToken!));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('已複製邀請碼')),
                                      );
                                    },
                                    icon: const Icon(Icons.copy_rounded, size: 18),
                                    label: const Text('複製'),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _busy ? null : () => _revokeInviteLink(request.id),
                                    icon: const Icon(Icons.link_off_rounded, size: 18),
                                    label: const Text('撤銷'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    OutlinedButton(
                      onPressed: _busy ? null : () => isOwner ? _cancelRequest(request.id) : _leaveRequest(request.id),
                      child: Text(isOwner ? '取消整個配對' : '退出房間'),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _getOrCreateInviteLink(String requestId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await getOrCreateInviteLink(ref.read(supabaseClientProvider), requestId);
      if (!mounted) return;
      setState(() => _inviteToken = token);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '產生邀請連結失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeInviteLink(String requestId) async {
    setState(() => _busy = true);
    try {
      await revokeInviteLink(ref.read(supabaseClientProvider), requestId);
      if (!mounted) return;
      setState(() => _inviteToken = null);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '撤銷失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveRequest(String requestId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確定要退出房間？'),
        content: const Text('退出後您將離開此配對房間。\n\n此操作不會有冷卻時間或信譽扣分。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('確定退出')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await leaveRequest(ref.read(supabaseClientProvider), requestId);
      if (!mounted) return;
      context.go('/match');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '退出失敗：${e.code.name}';
        _busy = false;
      });
    }
  }

  Future<void> _cancelRequest(String requestId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確定要取消整個配對？'),
        content: const Text('取消配對後房間將直接關閉，其他成員也會收到取消通知。\n\n此操作不會有冷卻時間或信譽扣分。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('確定取消')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await cancelRequest(ref.read(supabaseClientProvider), requestId);
      if (!mounted) return;
      context.go('/match');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '取消失敗：${e.code.name}';
        _busy = false;
      });
    }
  }
}

/// 等待室的情緒焦點——「還會不會配對成功」——原本只是塞在一張普通 [AppCard]
/// 裡的一小行文字，跟頁面上其他資訊卡片沒有視覺區別。這裡把倒數做成大字體的
/// 主視覺，搭配 [_MatchingPulse] 呼吸動畫，讓使用者一打開就知道「系統還在動、
/// 還剩多久」，不用在一堆卡片裡找。剩餘時間低於一分鐘時 [CountdownText] 自己
/// 會轉成錯誤色＋icon（見 countdown_text.dart 的 `urgentColor`）。
class _CountdownHeroCard extends StatelessWidget {
  const _CountdownHeroCard({required this.deadline});

  final DateTime deadline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg, horizontal: AppSpacing.md),
      child: Column(
        children: [
          const _MatchingPulse(),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '距離配對截止時間',
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          CountdownText(
            deadline: deadline,
            style: textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700),
            urgentColor: scheme.error,
          ),
        ],
      ),
    );
  }
}

/// 反饋：「房間下面有個配對中...之類的interactive感」——等待室原本除了倒數
/// 計時外沒有任何持續變化的元素，靜態到讓人懷疑畫面是不是卡住了。這裡加一顆
/// 呼吸閃爍的小圓點＋文字，純粹是「這個畫面還活著、系統還在背景幫你找人」的
/// 視覺回饋，不代表任何真實的配對引擎狀態（背景排程本身的節奏見
/// CLAUDE.md「Background jobs」一節）。
class _MatchingPulse extends StatefulWidget {
  const _MatchingPulse();

  @override
  State<_MatchingPulse> createState() => _MatchingPulseState();
}

class _MatchingPulseState extends State<_MatchingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: _controller.drive(CurveTween(curve: Curves.easeInOut)),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text('配對中…', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
      ],
    );
  }
}

class _AnonymousAvatar extends StatelessWidget {
  const _AnonymousAvatar({super.key, required this.isSelf, required this.isOwner});

  final bool isSelf;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: isSelf ? '你' : (isOwner ? '發起人' : '成員'),
      child: CircleAvatar(
        backgroundColor: isSelf ? scheme.primaryContainer : scheme.secondaryContainer,
        child: Icon(
          isOwner ? Icons.star_rounded : Icons.person_rounded,
          color: isSelf ? scheme.onPrimaryContainer : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

String _formatTime(DateTime t) => '${t.toLocal().hour.toString().padLeft(2, '0')}:${t.toLocal().minute.toString().padLeft(2, '0')}';

/// 反饋：「房間資訊也太少，至少顯示活動資訊吧，然後目前最少幾人成立之類的」
/// ——把 Request 上已有的活動類型、時間範圍、人數門檻顯示出來，讓等待中的
/// 成員知道自己在等什麼。
class _RequestInfoCard extends ConsumerWidget {
  const _RequestInfoCard({required this.request});

  final MatchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typeAsync = ref.watch(activityTypeByIdProvider(request.activityTypeId));
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 活動類型名稱
          Row(
            children: [
              Icon(Icons.category_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: typeAsync.when(
                  loading: () => Text('載入中…', style: textTheme.titleMedium),
                  error: (_, _) => Text('（未知活動）', style: textTheme.titleMedium),
                  data: (type) => Text(
                    type?.name ?? '（未知活動）',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // 時間範圍
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '${_formatTime(request.earliestStart)} ~ ${_formatTime(request.latestStart)}',
                  style: textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // 人數門檻
          Row(
            children: [
              Icon(Icons.group_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  request.maxParticipants != null
                      ? '${request.minParticipants}~${request.maxParticipants} 人成團'
                      : '至少 ${request.minParticipants} 人成團',
                  style: textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (request.allowDowngrade) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.tune_rounded, size: 20, color: scheme.tertiary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '允許人數調整',
                    style: textTheme.bodySmall?.copyWith(color: scheme.tertiary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          // 校區
          Row(
            children: [
              Icon(Icons.location_on_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '${schoolLabel(request.school)} ${request.campus}',
                  style: textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 狀態離開 REQUESTING 之後的過渡訊息——PENDING_CONFIRMATION/MATCHED 現在由
/// 「我的活動」round 1 接手（見 lib/activities/），這裡只負責證明 Realtime
/// 訂閱真的收到了狀態變化（UI_PLAN §3 技術要求）並把使用者導過去；ONGOING
/// 分頁籤本身（地點/成員）仍留到後續幾輪。
class _TransitionedState extends StatelessWidget {
  const _TransitionedState({required this.status});

  final REQUEST_STATUS status;

  @override
  Widget build(BuildContext context) {
    final (message, destination, buttonLabel) = switch (status) {
      REQUEST_STATUS.PENDING_CONFIRMATION => ('配對到人了！去「我的活動」完成小人數安全確認。', '/my-activities', '前往我的活動'),
      REQUEST_STATUS.MATCHED => ('配對成功！去「我的活動」看詳情。', '/my-activities', '前往我的活動'),
      REQUEST_STATUS.EXPIRED => ('這次配對沒有成立，別擔心，可以重新發起新的邀約。', '/match', '回配對頁'),
      REQUEST_STATUS.CANCELLED => ('這個配對已經取消了。', '/match', '回配對頁'),
      _ => ('狀態已變更：${status.name}', '/match', '回配對頁'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppCard(child: Text(message, textAlign: TextAlign.center)),
            const SizedBox(height: AppSpacing.lg),
            AppButton(label: buttonLabel, onPressed: () => context.go(destination)),
          ],
        ),
      ),
    );
  }
}
