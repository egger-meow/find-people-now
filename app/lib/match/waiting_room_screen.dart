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
import '../generated/supadart_header.dart'
    show REQUEST_MEMBER_ROLE, REQUEST_STATUS;
import '../notifications/web_push_service.dart';
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_error_state.dart';
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
        final status = next.value?.status;
        if (status != null && isTerminalForWaitingRoom(status)) {
          ref.invalidate(myActiveRequestProvider);
          ref.invalidate(myActiveActivityProvider);
          // 反饋：配對成功後點「前往我的活動」，清單卻還是配對前的「等待配對中」
          // ——這裡原本只 invalidate myActivityListProvider，但那個 provider 只是
          // watch 兩個來源 provider 組出來的，沒有連帶讓來源重新查詢，等於沒用
          // （見 invalidateMyActivityList 註解）。
          invalidateMyActivityList(ref);
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
                final statusContent = waitingRoomStatusContent(request.status);
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    AppStatusSummary(
                      title: statusContent.title,
                      message: statusContent.message,
                      leading: const MatchingPulse(),
                      deadline: '配對截止：${_formatDeadline(request.latestStart)}',
                      action: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Expanded(child: Text('剩餘時間')),
                              CountdownText(
                                deadline: request.latestStart,
                                style: Theme.of(context).textTheme.titleSmall,
                                urgentColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 狀態說明、下一步、無負擔退出與通知未驗證守則提醒
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  '配對進行中：\n'
                                  '• 目前狀態：系統正在比對時段與條件相容的同學。\n'
                                  '• 下一步驟：撮合成功後將進入雙向意願確認；雙方同意才正式成團。\n'
                                  '• 退出方式：可隨時取消或離開，無任何冷卻限制與信用扣分。',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Consumer(
                            builder: (context, ref, _) {
                              final pushStatus = ref.watch(pushPermissionStatusProvider).value ?? PushPermissionStatus.unsupported;
                              final String pushHint = switch (pushStatus) {
                                PushPermissionStatus.denied =>
                                  '提醒：瀏覽器通知權限已被關閉；背景推播功能尚在驗證中，離開 App 可能無法即時收到通知；請在截止前主動回到本畫面留意配對進度。',
                                PushPermissionStatus.granted =>
                                  '提醒：已允許通知；背景推播功能尚在驗證中，離開 App 可能無法即時收到通知；請在截止前主動回到本畫面留意配對進度。',
                                _ =>
                                  '提醒：背景推播功能尚在驗證中，離開 App 可能無法即時收到通知；請在截止前主動回到本畫面留意配對進度。',
                              };

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.notifications_active_outlined,
                                    size: 16,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(
                                    child: Text(
                                      pushHint,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppSection(
                      title: '配對條件',
                      description: '確認這次正在等待的活動、時間、人數與校區。',
                      child: _RequestInfoCard(request: request),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppSection(
                      title: '房間成員',
                      description:
                          '目前房間內有 ${members.length} 人。系統將依據校區、時段與各方條件綜合撮合，非單純達到人數即可保證成團。',
                      child: Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: [
                          for (final member in members)
                            _AnonymousAvatar(
                              key: ValueKey(member.id),
                              isSelf: member.userId == userId,
                              isOwner: member.role == REQUEST_MEMBER_ROLE.OWNER,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),

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
                      inviteToken: _inviteToken,
                      busy: _busy,
                      isOwner: isOwner,
                      onGenerate: () => _getOrCreateInviteLink(request.id),
                      onCopy: () {
                        Clipboard.setData(ClipboardData(text: _inviteToken!));
                        showAppSnackBar(context, '已複製邀請碼');
                      },
                      onRevoke: () => _revokeInviteLink(request.id),
                      onManage: () => isOwner
                          ? _cancelRequest(request.id)
                          : _leaveRequest(request.id),
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
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await getOrCreateInviteLink(
        ref.read(supabaseClientProvider),
        requestId,
      );
      if (!mounted) return;
      setState(() => _inviteToken = token);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorMessage(e));
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
      title: '確定要退出房間？',
      message: '退出後您將離開此配對房間。\n\n此操作不會有冷卻時間或信譽扣分。',
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
      title: '確定要取消整個配對？',
      message: '取消配對後房間將直接關閉，其他成員也會收到取消通知。\n\n此操作不會有冷卻時間或信譽扣分。',
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
    required this.onRevoke,
    required this.onManage,
  });

  final String? inviteToken;
  final bool busy;
  final bool isOwner;
  final VoidCallback onGenerate;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSection(
          title: '邀請朋友',
          description:
              '系統會同時在背景自動幫你配對其他也在等的人，不是只能靠邀請朋友湊人數。'
              '想約特定朋友的話，請他們盡快用邀請碼加入——如果人數在朋友加入前就湊滿，'
              '房間可能已經跟別人成團。',
          child: inviteToken == null
              ? AppButton(
                  label: '邀請朋友',
                  loading: busy,
                  onPressed: busy ? null : onGenerate,
                )
              : AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '邀請碼（分享給朋友）',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: SelectableText(
                          inviteToken!,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
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
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: busy ? null : onCopy,
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: const Text('複製'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: busy ? null : onRevoke,
                              icon: const Icon(
                                Icons.link_off_rounded,
                                size: 18,
                              ),
                              label: const Text('撤銷'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppSection(
          title: '管理配對',
          description: isOwner
              ? '取消配對後房間將關閉；此操作無冷卻限制且不影響信譽評分。'
              : '離開後將退出這個房間；無冷卻限制且不影響信譽評分。',
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: busy ? null : onManage,
              child: Text(isOwner ? '取消整個配對' : '退出房間'),
            ),
          ),
        ),

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

class _AnonymousAvatar extends StatelessWidget {
  const _AnonymousAvatar({
    super.key,
    required this.isSelf,
    required this.isOwner,
  });

  final bool isSelf;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: isSelf ? '你' : (isOwner ? '發起人' : '成員'),
      child: CircleAvatar(
        backgroundColor: isSelf
            ? scheme.primaryContainer
            : scheme.secondaryContainer,
        child: Icon(
          isOwner ? Icons.star_rounded : Icons.person_rounded,
          color: isSelf
              ? scheme.onPrimaryContainer
              : scheme.onSecondaryContainer,
        ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: AppStatusSummary(
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
        message: '這次配對沒有成立，別擔心，可以重新發起新的邀約。',
        actionLabel: '回配對頁',
        destination: '/match',
        icon: Icons.schedule_outlined,
      ),
      REQUEST_STATUS.CANCELLED => const WaitingRoomStatusContent(
        title: '配對已取消',
        message: '這個配對已經關閉，你可以回配對頁再找一次。',
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
