import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../activities/my_activities_providers.dart'
    show invalidateMyActivityList;
import '../auth/auth_providers.dart';
import '../data/school_labels.dart';
import '../data/sport_level_config.dart';
import '../errors/user_error_message.dart';
import '../generated/match_request.dart';
import '../generated/request_member.dart';
import '../generated/supadart_header.dart'
    show REQUEST_MEMBER_ROLE, REQUEST_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_error_state.dart';
import '../widgets/app_mascot_stage.dart';
import '../widgets/app_section.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_status_summary.dart';
import '../widgets/countdown_text.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';

/// UI_PLAN.md §3 等待室——技術要求明講必須用 Supabase Realtime 訂閱
/// `match_request` 狀態變化，不能只靠靜態載入或使用者手動刷新。這裡同時訂閱
/// `request_member`（成員人數變化）與 `match_request`（狀態變化）兩條 Realtime
/// stream（見 lib/match/match_providers.dart）。
///
/// 同房間同夥成員（透過邀請碼/連結加入同一個 Request 的既有好友）在此顯示真實頭貼與暱稱
/// （透過 get_request_member_profiles RPC，API §3.10），讓揪團者清楚確認好友是否到齊。
/// 盲配設計精神（UI_PLAN §8.2）僅適用於配對過程中其他不同 Request 的陌生對象，同房間內的夥伴並非陌生人。
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
  bool _autoFetchInviteAttempted = false;

  @override
  Widget build(BuildContext context) {
    // 反饋：使用者回報「配對中，選活動畫面還是可以去選」/取消配對後配對頁
    // 卡在「你已經有進行中的配對」loop——根因是 myActiveRequestProvider／
    // myActiveActivityProvider 都是普通 FutureProvider，配對引擎（背景排程）
    // 把狀態從 REQUESTING 轉成 PENDING_CONFIRMATION/MATCHED/EXPIRED 這種
    // 不是使用者自己在這個畫面點出來的變化，原本完全不會讓這兩個 provider
    // 失效。這裡直接監聽 Realtime 狀態流，一旦狀態離開 REQUESTING 就讓兩個
    // provider 失效，不管是引擎自動撮合、還是其他成員取消/退出造成的。
    ref.listen<AsyncValue<MatchRequest?>>(
      matchRequestStreamProvider(widget.requestId),
      (previous, next) {
        final req = next.value;
        if (req != null) {
          // 當收到跨裝置撤銷推播（revokedAt 被設定）時，立即清空本地快取的 invite token
          if (req.revokedAt != null && _inviteToken != null) {
            setState(() => _inviteToken = null);
          }
          final status = req.status;
          if (isTerminalForWaitingRoom(status)) {
            if (_inviteToken != null) {
              setState(() => _inviteToken = null);
            }
            _autoFetchInviteAttempted = false;
            ref.invalidate(myActiveRequestProvider);
            ref.invalidate(myActiveActivityProvider);
            invalidateMyActivityList(ref);
          }
        }
      },
    );

    final requestAsync = ref.watch(
      matchRequestStreamProvider(widget.requestId),
    );
    final membersAsync = ref.watch(
      requestMembersStreamProvider(widget.requestId),
    );
    final userId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('等待室')),
      body: SafeArea(
        child: requestAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => const AppErrorState(),
          data: (request) {
            if (request == null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_off_rounded,
                        size: 44,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        '找不到這個配對，可能已經結束或已取消',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton(
                        label: '返回首頁',
                        onPressed: () => context.go('/match'),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (isTerminalForWaitingRoom(request.status)) {
              return _TransitionedState(status: request.status);
            }

            return membersAsync.when(
              loading: () => const LoadingIndicator(),
              error: (error, stack) => const AppErrorState(),
              data: (members) {
                final isOwner = members.any(
                  (m) =>
                      m.userId == userId && m.role == REQUEST_MEMBER_ROLE.OWNER,
                );
                final isRevoked = request.revokedAt != null;
                if (isRevoked && _inviteToken != null) {
                  _inviteToken = null;
                }
                final effectiveInviteToken =
                    isRevoked ? null : (_inviteToken ?? request.inviteToken);

                if (isOwner &&
                    !isRevoked &&
                    effectiveInviteToken == null &&
                    !_busy &&
                    !_autoFetchInviteAttempted) {
                  _autoFetchInviteAttempted = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _getOrCreateInviteLink(request.id);
                  });
                }

                final statusContent = waitingRoomStatusContent(request.status);
                return RefreshIndicator(
                  onRefresh: () async {
                    await Future.wait([
                      ref.refresh(
                        matchRequestStreamProvider(widget.requestId).future,
                      ),
                      ref.refresh(
                        requestMembersStreamProvider(widget.requestId).future,
                      ),
                    ]);
                  },
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (request.status == REQUEST_STATUS.REQUESTING) ...[
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.only(bottom: AppSpacing.xs),
                              child: AppMascotStage(
                                assetPath: 'assets/mascot/matching.png',
                                height: 52,
                                style: AppMascotStageStyle.waiting,
                                semanticLabel: '街街貓正在幫你找夥伴',
                              ),
                            ),
                          ),
                        ],
                        AppStatusSummary(
                          title: statusContent.title,
                          message: statusContent.message,
                          leading: const MatchingPulse(),
                          deadline:
                              '配對截止：${_formatDeadline(request.latestStart)}',
                          action: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const Expanded(child: Text('距配對截止時間')),
                                  CountdownText(
                                    deadline: request.latestStart,
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
                                    urgentColor: Theme.of(
                                      context,
                                    ).colorScheme.error,
                                    expiredLabel: '正在確認配對結果',
                                    onExpired: () {
                                      ref.invalidate(
                                        matchRequestStreamProvider(
                                          widget.requestId,
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                '非預估等待時間。配對為系統非同步撮合，若截止未滿額將自動安全結束，不影響信譽評分。您可安心離開畫面，配對成功時將發送通知。',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontSize: 11.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        _RequestInfoCard(request: request),
                        const SizedBox(height: AppSpacing.sm),
                        RoomMembersSection(
                          requestId: request.id,
                          members: members,
                          currentUserId: userId,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_error != null) ...[
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        WaitingRoomActionSections(
                          inviteToken: effectiveInviteToken,
                          busy: _busy,
                          isOwner: isOwner,
                          isRevoked: isRevoked,
                          onGenerate: () => _getOrCreateInviteLink(request.id),
                          onCopy: () async {
                            if (effectiveInviteToken == null) return;
                            await Clipboard.setData(
                              ClipboardData(text: effectiveInviteToken),
                            );
                            if (context.mounted) {
                              showAppSnackBar(context, '已複製邀請碼');
                            }
                          },
                          onShare: () async {
                            if (effectiveInviteToken == null) return;
                            final shareText =
                                '來跟我一起參加配對！\n打開「敢不敢揪」App ➔ 首頁右上角點擊「輸入邀請碼」圖示 ➔ 貼上「$effectiveInviteToken」即可加入同一個房間！';
                            await Clipboard.setData(
                              ClipboardData(text: shareText),
                            );
                            if (context.mounted) {
                              showAppSnackBar(context, '已複製邀請訊息，可直接貼給朋友');
                            }
                          },
                          onRevoke: () => _revokeInviteLink(request.id),
                          onManage: () => isOwner
                              ? _cancelRequest(request.id)
                              : _leaveRequest(request.id),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        _WaitingTrustCard(latestStart: request.latestStart),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _getOrCreateInviteLink(String requestId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      final token = await getOrCreateInviteLink(
        client,
        requestId,
      );
      if (!mounted) return;
      setState(() => _inviteToken = token);
      ref.invalidate(matchRequestStreamProvider(requestId));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorMessage(e));
    } catch (_) {
      // 網路或未初始化環境防護，不讓等待室崩潰
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeInviteLink(String requestId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await revokeInviteLink(ref.read(supabaseClientProvider), requestId);
      if (!mounted) return;
      setState(() => _inviteToken = null);
      ref.invalidate(matchRequestStreamProvider(requestId));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveRequest(String requestId) async {
    if (_busy) return;
    final confirm = await showAppConfirmDialog(
      context,
      title: '確定要退出等待？',
      message: '取消後將退出本次配對等待，其他等待中的夥伴將繼續等待。\n\n此操作不會有冷卻時間或信譽扣分。',
      cancelLabel: '返回',
      confirmLabel: '確定退出',
    );
    if (!confirm || !mounted) return;

    setState(() => _busy = true);
    try {
      await leaveRequest(ref.read(supabaseClientProvider), requestId);
      ref.invalidate(myActiveRequestProvider);
      if (!mounted) return;
      context.go('/match');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorMessage(e);
        _busy = false;
      });
    }
  }

  Future<void> _cancelRequest(String requestId) async {
    if (_busy) return;
    final confirm = await showAppConfirmDialog(
      context,
      title: '確定要取消配對？',
      message: '取消後將退出本次配對等待，房間將關閉。\n\n此操作不會有冷卻時間或信譽扣分。',
      cancelLabel: '返回',
      confirmLabel: '確定取消',
    );
    if (!confirm || !mounted) return;

    setState(() => _busy = true);
    try {
      await cancelRequest(ref.read(supabaseClientProvider), requestId);
      ref.invalidate(myActiveRequestProvider);
      if (!mounted) return;
      context.go('/match');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorMessage(e);
        _busy = false;
      });
    }
  }
}

/// 房間成員區塊：呈現總人數並以同房間夥伴之真實頭像與暱稱呈現（超過 5 人以 +N 緊湊呈現）。
/// 透過 [requestMemberProfilesProvider] 取得真實資訊（API §3.10），
/// 當資料尚未載入或在測試環境時，優雅回退至預設標籤，確保向下相容與穩定性。
class RoomMembersSection extends ConsumerWidget {
  const RoomMembersSection({
    super.key,
    required this.requestId,
    required this.members,
    required this.currentUserId,
    this.showTitle = true,
  });

  final String requestId;
  final List<RequestMember> members;
  final String? currentUserId;
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasSelf = members.any((m) => m.userId == currentUserId);
    final countLabel = hasSelf
        ? '目前 ${members.length} 人（含你）'
        : '目前 ${members.length} 人';

    const maxVisible = 5;
    final visibleMembers = members.take(maxVisible).toList();
    final extraCount = members.length - visibleMembers.length;

    final profilesAsync = ref.watch(requestMemberProfilesProvider(requestId));
    final profiles = profilesAsync.value ?? const [];
    final profileByUserId = {for (final p in profiles) p.userId: p};

    final content = Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final member in visibleMembers)
          RoomMemberAvatar(
            key: ValueKey(member.id),
            profile: profileByUserId[member.userId],
            member: member,
            isSelf: member.userId == currentUserId,
            isOwner: member.role == REQUEST_MEMBER_ROLE.OWNER,
          ),
        if (extraCount > 0)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: scheme.surfaceContainerHighest,
                child: Text(
                  '+$extraCount',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 58,
                child: Text(
                  '更多',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
      ],
    );

    if (!showTitle) return content;

    return AppSection(
      title: '房間成員 · $countLabel',
      child: content,
    );
  }
}

/// Testable production actions shared by the live waiting room and widget
/// regressions. RPC/dialog behavior remains owned by [WaitingRoomScreen].
class WaitingRoomActionSections extends StatelessWidget {
  const WaitingRoomActionSections({
    super.key,
    required this.inviteToken,
    required this.busy,
    required this.isOwner,
    required this.onGenerate,
    required this.onCopy,
    required this.onManage,
    this.isRevoked = false,
    this.onRevoke,
    this.onShare,
    this.showManageAction = true,
  });

  final String? inviteToken;
  final bool busy;
  final bool isOwner;
  final bool isRevoked;
  final VoidCallback onGenerate;
  final VoidCallback onCopy;
  final VoidCallback onManage;
  final VoidCallback? onRevoke;
  final VoidCallback? onShare;
  final bool showManageAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inviteToken != null) ...[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.group_add_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '邀請朋友',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '邀請碼：',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          inviteToken!,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontFamilyFallback: const [
                              'Menlo',
                              'Courier New',
                              'monospace',
                            ],
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final textScale = MediaQuery.textScalerOf(
                      context,
                    ).scale(1.0);
                    // 當可用寬度小於 330 或字級放大超過 1.15 時，自動轉為垂直堆疊以確保無障礙 Dynamic Type 不破版
                    final isNarrowOrLargeFont =
                        constraints.maxWidth < 330 || textScale > 1.15;

                    if (isNarrowOrLargeFont) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          OutlinedButton.icon(
                            onPressed: busy ? null : onCopy,
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('複製邀請碼'),
                          ),
                          if (onShare != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            FilledButton.tonalIcon(
                              onPressed: busy ? null : onShare,
                              icon: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 18,
                              ),
                              label: const Text('複製邀請訊息'),
                            ),
                          ],
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : onCopy,
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('複製邀請碼'),
                          ),
                        ),
                        if (onShare != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: busy ? null : onShare,
                              icon: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 18,
                              ),
                              label: const Text('複製邀請訊息'),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
                if (isOwner && onRevoke != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: busy ? null : onRevoke,
                      icon: const Icon(Icons.link_off_rounded, size: 16),
                      label: const Text('撤銷邀請碼'),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ] else if (isOwner) ...[
          if (isRevoked) ...[
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.link_off_rounded,
                        size: 20,
                        color: scheme.error,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        '邀請碼已撤銷',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '目前的邀請碼已失效，朋友無法透過舊連結加入。如需再次邀請，請重新產生。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: busy ? '重新產生中…' : '重新產生邀請碼',
                    loading: busy,
                    onPressed: busy ? null : onGenerate,
                  ),
                ],
              ),
            ),
          ] else ...[
            AppButton(
              label: busy ? '準備邀請碼…' : '邀請朋友',
              loading: busy,
              onPressed: busy ? null : onGenerate,
            ),
          ],
        ] else ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Center(
              child: Text(
                isRevoked ? '邀請碼已被房主撤銷' : '等待房主產生邀請碼',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
        if (showManageAction) ...[
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: busy ? null : onManage,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Text(isOwner ? '取消整個配對' : '退出房間'),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: Text(
              isOwner ? '此操作無冷卻限制且不影響信譽評分' : '無冷卻限制且不影響信譽評分',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 反饋：「房間下面有個配對中...之類的interactive感」——等待室原本除了倒數
/// 計時外沒有任何持續變化的元素，靜態到讓人懷疑畫面是不是卡住了。這裡加一顆
/// 呼吸閃爍的小圓點＋文字，純粹是「這個畫面還活著、系統還在背景幫你找人」的
/// 視覺回饋，不代表任何真實的配對引擎狀態（背景排程本身的節奏見
/// CLAUDE.md「Background jobs」一節）。
class MatchingPulse extends StatefulWidget {
  const MatchingPulse({super.key});

  @override
  State<MatchingPulse> createState() => _MatchingPulseState();
}

class _MatchingPulseState extends State<MatchingPulse>
    with TickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final allowsDecorative = AppMotion.allowsDecorative(context);
    if (allowsDecorative && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1000),
      )..repeat(reverse: true);
    } else if (!allowsDecorative && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller == null)
          Container(
            key: const ValueKey('matching-static-glyph'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          )
        else
          FadeTransition(
            key: const ValueKey('matching-animated-glyph'),
            opacity: controller.drive(CurveTween(curve: Curves.easeInOut)),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          '配對中…',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.primary),
        ),
      ],
    );
  }
}

/// 同房間夥伴頭像與暱稱標籤
class RoomMemberAvatar extends StatelessWidget {
  const RoomMemberAvatar({
    super.key,
    this.profile,
    this.member,
    required this.isSelf,
    required this.isOwner,
  });

  final RequestMemberProfile? profile;
  final RequestMember? member;
  final bool isSelf;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final displayName = profile?.displayName ??
        (isSelf ? '你' : (isOwner ? '發起人' : '成員'));
    final avatarUrl = profile?.avatarUrl;
    final hasValidAvatar = avatarUrl != null &&
        avatarUrl.isNotEmpty &&
        avatarUrl.startsWith('http');
    final tooltipMessage = isSelf
        ? (profile != null ? '$displayName (你)' : '你')
        : (isOwner ? '$displayName (發起人)' : displayName);

    return Tooltip(
      message: tooltipMessage,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isOwner
                        ? Colors.amber.shade600
                        : (isSelf ? scheme.primary : Colors.transparent),
                    width: 2,
                  ),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: isSelf
                      ? scheme.primaryContainer
                      : (isOwner ? Colors.amber.shade50 : scheme.secondaryContainer),
                  backgroundImage:
                      hasValidAvatar ? NetworkImage(avatarUrl) : null,
                  child: !hasValidAvatar
                      ? (profile != null &&
                              displayName.isNotEmpty &&
                              displayName != '成員' &&
                              displayName != '發起人')
                          ? Text(
                              displayName.characters.first.toUpperCase(),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: isSelf
                                    ? scheme.onPrimaryContainer
                                    : (isOwner
                                        ? Colors.amber.shade900
                                        : scheme.onSecondaryContainer),
                              ),
                            )
                          : Icon(
                              isOwner
                                  ? Icons.star_rounded
                                  : Icons.person_rounded,
                              color: isSelf
                                  ? scheme.onPrimaryContainer
                                  : (isOwner
                                      ? Colors.amber.shade800
                                      : scheme.onSecondaryContainer),
                            )
                      : null,
                ),
              ),
              if (isOwner)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade600,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.scaffoldBackgroundColor,
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.star_rounded,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 58,
            child: Text(
              isSelf && profile != null ? '$displayName (你)' : displayName,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: isSelf ? FontWeight.bold : FontWeight.w500,
                color: isSelf ? scheme.primary : scheme.onSurface,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime t) =>
    '${t.toLocal().hour.toString().padLeft(2, '0')}:${t.toLocal().minute.toString().padLeft(2, '0')}';

String _formatDeadline(DateTime t) {
  final local = t.toLocal();
  return '${local.month}/${local.day} ${_formatTime(local)}';
}

/// 反饋：「房間資訊也太少，至少顯示活動資訊吧，然後目前最少幾人成立之類的」
/// ——把 Request 上已有的活動類型、時間範圍、人數門檻顯示出來，讓等待中的
/// 成員知道自己在等什麼。
class _RequestInfoCard extends ConsumerWidget {
  const _RequestInfoCard({required this.request});

  final MatchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typeAsync = ref.watch(
      activityTypeByIdProvider(request.activityTypeId),
    );
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
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
          typeAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (type) {
              final sportConfig = SportLevelConfig.forSystem(type?.levelSystem);
              if (sportConfig == null || request.sportLevel == null) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  children: [
                    Icon(
                      Icons.military_tech_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        sportConfig.formatFieldSummary(
                          request.sportLevel,
                          rating: request.sportLevelRating,
                        ),
                        style: textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (request.studyTarget != null &&
              request.studyTarget!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.menu_book_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '讀書目標：${request.studyTarget}',
                    style: textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
          if (request.allowDowngrade) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.tune_rounded, size: 20, color: scheme.tertiary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '允許人數調整',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.tertiary,
                    ),
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
    final content = waitingRoomStatusContent(status);

    if (status == REQUEST_STATUS.MATCHED) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppMascotStage(
                assetPath: 'assets/mascot/matched.png',
                height: 120,
                style: AppMascotStageStyle.celebration,
                semanticLabel: '街街貓慶祝配對成功',
              ),
              const SizedBox(height: AppSpacing.md),
              AppStatusSummary(
                title: content.title,
                message: content.message,
                leading: Icon(
                  Icons.celebration_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                action: SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    label: content.actionLabel,
                    onPressed: () => context.go(content.destination),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isExpired = status == REQUEST_STATUS.EXPIRED;
    final isCancelled = status == REQUEST_STATUS.CANCELLED;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isExpired || isCancelled)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppMascotStage(
                  assetPath: 'assets/mascot/explore_empty.png',
                  height: 96,
                  style: AppMascotStageStyle.card,
                  semanticLabel:
                      isExpired ? '街街貓提醒這次沒有成團' : '街街貓已為你取消配對',
                ),
              ),
            AppStatusSummary(
              title: content.title,
              message: content.message,
              leading: Icon(
                content.icon,
                color: Theme.of(context).colorScheme.primary,
              ),
              action: SizedBox(
                width: double.infinity,
                child: AppButton(
                  label: content.actionLabel,
                  onPressed: () => context.go(content.destination),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WaitingRoomStatusContent {
  const WaitingRoomStatusContent({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.destination,
    required this.icon,
  });

  final String title;
  final String message;
  final String actionLabel;
  final String destination;
  final IconData icon;
}

WaitingRoomStatusContent waitingRoomStatusContent(REQUEST_STATUS status) =>
    switch (status) {
      REQUEST_STATUS.REQUESTING => const WaitingRoomStatusContent(
        title: '正在幫你找人',
        message: '系統會持續配對，也可以邀請朋友加入這個房間。',
        actionLabel: '邀請朋友',
        destination: '/waiting-room',
        icon: Icons.people_outline,
      ),
      REQUEST_STATUS.PENDING_CONFIRMATION => const WaitingRoomStatusContent(
        title: '找到候選夥伴',
        message: '已找到候選夥伴，請前往「我的活動」完成小人數安全確認。',
        actionLabel: '前往我的活動',
        destination: '/my-activities',
        icon: Icons.verified_user_outlined,
      ),
      REQUEST_STATUS.MATCHED => const WaitingRoomStatusContent(
        title: '配對成功',
        message: '夥伴都確認了，前往「我的活動」查看活動詳情。',
        actionLabel: '前往我的活動',
        destination: '/my-activities',
        icon: Icons.celebration_outlined,
      ),
      REQUEST_STATUS.EXPIRED => const WaitingRoomStatusContent(
        title: '這次沒有成團',
        message: '已達截止時間，這次配對沒有成立（無冷卻限制且不扣信譽）。別擔心，可以重新發起新的邀約，或設定時效提醒。',
        actionLabel: '回配對頁',
        destination: '/match',
        icon: Icons.schedule_outlined,
      ),
      REQUEST_STATUS.CANCELLED => const WaitingRoomStatusContent(
        title: '配對已取消',
        message: '這個配對已經關閉（無冷卻限制且不影響信譽）。你可以回配對頁再找一次。',
        actionLabel: '回配對頁',
        destination: '/match',
        icon: Icons.cancel_outlined,
      ),
      _ => WaitingRoomStatusContent(
        title: '配對狀態已更新',
        message: '狀態已變更：${status.name}',
        actionLabel: '回配對頁',
        destination: '/match',
        icon: Icons.info_outline,
      ),
    };

/// 安心等待承諾與透明規則說明卡（Direction 4：漸進式揭露）
class _WaitingTrustCard extends StatefulWidget {
  const _WaitingTrustCard({required this.latestStart});

  final DateTime latestStart;

  @override
  State<_WaitingTrustCard> createState() => _WaitingTrustCardState();
}

class _WaitingTrustCardState extends State<_WaitingTrustCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return AppCard(
      onTap: () {
        setState(() => _expanded = !_expanded);
      },
      semanticLabel: _expanded
          ? '安心等待承諾，點擊收合說明'
          : '安心等待承諾，無冷卻、不扣評分、隨時可退出，點擊展開完整規則說明',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '安心等待承諾',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                      ),
                    ),
                    if (!_expanded) ...[
                      const SizedBox(height: 2),
                      Text(
                        '無冷卻時間・不扣信用評分・隨時可退出',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: AppSpacing.sm),
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
            const SizedBox(height: AppSpacing.sm),
            _TrustItem(
              icon: Icons.timer_outlined,
              title: '等到何時？',
              description:
                  '最晚撮合至 ${_formatDeadline(widget.latestStart)} 截止。',
            ),
            const SizedBox(height: AppSpacing.xs),
            const _TrustItem(
              icon: Icons.check_circle_outline_rounded,
              title: '取消會怎樣？',
              description:
                  '等待期間取消或退出，無冷卻時間、不扣信譽評分，可隨時重新發起。',
            ),
            const SizedBox(height: AppSpacing.xs),
            const _TrustItem(
              icon: Icons.sentiment_satisfied_alt_rounded,
              title: '沒配到會怎樣？',
              description:
                  '若未成團將自動安全截止，不扣分、無懲罰，亦不發送打擾推播。',
            ),
            const SizedBox(height: AppSpacing.xs),
            const _TrustItem(
              icon: Icons.notifications_none_rounded,
              title: '通知如何送達？',
              description:
                  'App 開啟時即時更新；關閉 App 時無法保證系統推播，建議在截止前開啟 App 查看。',
            ),
          ],
        ],
      ),
    );
  }
}

class _TrustItem extends StatelessWidget {
  const _TrustItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              children: [
                TextSpan(
                  text: '$title ',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                TextSpan(text: description),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
