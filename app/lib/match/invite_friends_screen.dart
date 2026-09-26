import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../errors/user_error_message.dart';
import '../generated/supadart_header.dart' show REQUEST_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import 'match_providers.dart';
import 'waiting_room_screen.dart' show WaitingRoomActionSections;

/// A draft cannot be matched. The owner submits it only after invited friends
/// have joined, so the invitation step happens before the waiting room.
class InviteFriendsScreen extends ConsumerStatefulWidget {
  const InviteFriendsScreen({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<InviteFriendsScreen> createState() =>
      _InviteFriendsScreenState();
}

class _InviteFriendsScreenState extends ConsumerState<InviteFriendsScreen> {
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadToken);
  }

  Future<void> _loadToken() async {
    try {
      final request = await ref.read(
        matchRequestStreamProvider(widget.requestId).future,
      );
      if (!mounted || request?.ownerId != ref.read(currentUserIdProvider)) {
        return;
      }
      final token = await getOrCreateInviteLink(
        ref.read(supabaseClientProvider),
        widget.requestId,
      );
      if (mounted) {
        setState(() => _token = token);
        ref.invalidate(myActiveRequestProvider);
        ref.invalidate(matchRequestStreamProvider(widget.requestId));
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = userErrorMessage(error));
    } catch (_) {
      if (mounted) setState(() => _error = '無法載入邀請碼，請稍後再試');
    }
  }

  Future<void> _startMatching() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await submitRequest(ref.read(supabaseClientProvider), widget.requestId);
      if (!mounted) return;
      ref.invalidate(myActiveRequestProvider);
      context.go('/waiting-room/${widget.requestId}');
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = userErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeToken() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await revokeInviteLink(
        ref.read(supabaseClientProvider),
        widget.requestId,
      );
      if (!mounted) return;
      setState(() => _token = null);
      ref.invalidate(matchRequestStreamProvider(widget.requestId));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = userErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveDraft(bool isOwner) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      if (isOwner) {
        await cancelRequest(client, widget.requestId);
      } else {
        await leaveRequest(client, widget.requestId);
      }
      if (!mounted) return;
      ref.invalidate(myActiveRequestProvider);
      context.go('/match');
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = userErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(matchRequestStreamProvider(widget.requestId), (previous, next) {
      if (next.value?.status == REQUEST_STATUS.REQUESTING && mounted) {
        context.go('/waiting-room/${widget.requestId}');
      }
    });
    final request = ref.watch(matchRequestStreamProvider(widget.requestId));
    final members = ref.watch(requestMembersStreamProvider(widget.requestId));
    final userId = ref.watch(currentUserIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('邀請朋友')),
      body: request.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('無法載入邀請，請重新整理')),
        data: (value) {
          if (value == null) return const Center(child: Text('找不到這筆邀請'));
          if (value.status != REQUEST_STATUS.DRAFT) {
            return Center(
              child: TextButton(
                onPressed: () => context.go(
                  value.status == REQUEST_STATUS.REQUESTING
                      ? '/waiting-room/${widget.requestId}'
                      : '/my-activities',
                ),
                child: Text(
                  value.status == REQUEST_STATUS.REQUESTING
                      ? '前往等待室'
                      : '邀請已結束，返回我的活動',
                ),
              ),
            );
          }
          final isOwner = value.ownerId == userId;
          final expired = !value.latestStart.isAfter(DateTime.now());
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('先把朋友加進來', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                expired ? '邀請時段已過，請取消後重新建立。' : '這時還不會開始自動配對。大家到齊後，由發起人確認進入等待室。',
              ),
              const SizedBox(height: 24),
              Text(
                '目前 ${members.value?.length ?? 1} 人（含發起人）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              WaitingRoomActionSections(
                inviteToken: value.revokedAt == null
                    ? (_token ?? value.inviteToken)
                    : null,
                busy: _busy,
                isOwner: isOwner,
                isRevoked: value.revokedAt != null,
                onGenerate: _loadToken,
                onCopy: () async {
                  final token = _token ?? value.inviteToken;
                  if (token == null) return;
                  await Clipboard.setData(ClipboardData(text: token));
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('邀請碼已複製')));
                  }
                },
                onShare: () async {
                  final token = _token ?? value.inviteToken;
                  if (token == null) return;
                  await Clipboard.setData(
                    ClipboardData(text: '來跟我一起參加活動！邀請碼：$token'),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('邀請訊息已複製')));
                  }
                },
                onRevoke: isOwner ? _revokeToken : null,
                onManage: () => _leaveDraft(isOwner),
              ),
              if (isOwner) ...[
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy || expired ? null : _startMatching,
                  child: Text(_busy ? '送出中…' : '人都進來了，開始配對'),
                ),
              ] else
                const Text('等待發起人確認人都進來後開始配對。'),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
