import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../generated/activity_type.dart';
import '../generated/supadart_header.dart' show REQUEST_STATUS;
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';

/// UI_PLAN.md §2 配對頁（首頁）— 這輪只做填表 → 送出 → 等待室這一條路徑。
/// §7 時段桶 UI 標記為 🔴 尚未細化，這輪先用最單純的「現在，2 小時內」固定窗口
/// 頂上去，讓 create_request/submit_request 這條路徑先能真的跑——之後桶 UI 定案
/// 後這裡只需要換算邏輯，不影響 RPC 呼叫本身（earliest_start/latest_start 早已是
/// 前端算好傳原始時間戳，v1.16）。
class CreateRequestScreen extends ConsumerWidget {
  const CreateRequestScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRequest = ref.watch(myActiveRequestProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('找人一起做點事'),
        actions: [
          IconButton(
            icon: const Icon(Icons.event_note_rounded),
            tooltip: '我的活動',
            onPressed: () => context.go('/my-activities'),
          ),
        ],
      ),
      body: SafeArea(
        child: activeRequest.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('載入失敗：$error')),
          data: (request) {
            if (request == null) {
              return const _CreateRequestForm();
            }
            if (request.status == REQUEST_STATUS.REQUESTING) {
              // UI_PLAN §2.2 送出前預先攔截 — 已有進行中的 Request 就直接導去
              // 等待室，不重新顯示表單。用 post-frame callback 避免在 build
              // 中途觸發導覽。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) context.go('/waiting-room/${request.id}');
              });
              return const LoadingIndicator(label: '你已經有進行中的配對，正在帶你過去…');
            }
            // MATCHED/ONGOING — 「我的活動」round 1 已經接手這個過渡點。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/my-activities');
            });
            return const LoadingIndicator(label: '你的活動已經成團了，正在帶你去「我的活動」…');
          },
        ),
      ),
    );
  }
}

class _CreateRequestForm extends ConsumerStatefulWidget {
  const _CreateRequestForm();

  @override
  ConsumerState<_CreateRequestForm> createState() => _CreateRequestFormState();
}

class _CreateRequestFormState extends ConsumerState<_CreateRequestForm> {
  ActivityType? _selectedType;
  String? _selectedCampus;
  int? _selectedHeadcount;
  bool _allowDowngrade = false;
  bool _submitting = false;
  String? _error;

  List<int> _groupSizeOptions(ActivityType type) {
    final min = type.defaultMinParticipants ?? 2;
    final max = type.defaultMaxParticipants ?? min;
    final step = (type.groupSizeStep != null && type.groupSizeStep! > 0) ? type.groupSizeStep! : 1;
    return [for (var v = min; v <= max; v += step) v];
  }

  Future<void> _submit() async {
    final type = _selectedType;
    final campus = _selectedCampus;
    final headcount = _selectedHeadcount;
    if (type == null || campus == null || headcount == null) {
      setState(() => _error = '請完成所有選擇');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final client = ref.read(supabaseClientProvider);
    try {
      final now = DateTime.now().toUtc();
      final request = await createRequest(
        client,
        activityTypeId: type.id,
        campus: campus,
        earliestStart: now,
        latestStart: now.add(const Duration(hours: 2)),
        minParticipants: headcount,
        allowDowngrade: _allowDowngrade,
      );
      await submitRequest(client, request.id);
      if (!mounted) return;
      context.go('/waiting-room/${request.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗：${e.code.name}${e.detail != null ? '（${e.detail}）' : ''}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typesAsync = ref.watch(activityTypesProvider);
    final userAsync = ref.watch(myAppUserProvider);
    final reliabilityAsync = ref.watch(myReliabilityProvider);

    return typesAsync.when(
      loading: () => const LoadingIndicator(),
      error: (error, stack) => Center(child: Text('載入活動類型失敗：$error')),
      data: (types) => userAsync.when(
        loading: () => const LoadingIndicator(),
        error: (error, stack) => Center(child: Text('載入個人資料失敗：$error')),
        data: (user) {
          if (user == null) return const LoadingIndicator();
          final campusAsync = ref.watch(campusOptionsProvider(user.school));

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text('1. 選活動類型', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final type in types)
                    ChoiceChip(
                      label: Text(type.name),
                      selected: _selectedType?.id == type.id,
                      onSelected: (_) => setState(() {
                        _selectedType = type;
                        _selectedHeadcount = null;
                      }),
                    ),
                ],
              ),
              if (_selectedType?.description != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _selectedType!.description!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Text('2. 選校區', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              campusAsync.when(
                loading: () => const LoadingIndicator(),
                error: (error, stack) => Text('載入校區失敗：$error'),
                data: (campuses) {
                  if (campuses.isNotEmpty && _selectedCampus == null) {
                    _selectedCampus = campuses.first;
                  }
                  return Wrap(
                    spacing: AppSpacing.sm,
                    children: [
                      for (final campus in campuses)
                        ChoiceChip(
                          label: Text(campus),
                          selected: _selectedCampus == campus,
                          onSelected: (_) => setState(() => _selectedCampus = campus),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('3. 選人數', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              if (_selectedType == null)
                Text('請先選活動類型', style: Theme.of(context).textTheme.bodySmall)
              else
                reliabilityAsync.when(
                  loading: () => const LoadingIndicator(),
                  error: (error, stack) => Text('載入可信度失敗：$error'),
                  data: (reliability) {
                    final options = _groupSizeOptions(_selectedType!);
                    return Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        for (final n in options)
                          ChoiceChip(
                            label: Text('$n 人'),
                            selected: _selectedHeadcount == n,
                            // UI_PLAN §2.2：New tier 使用者 ≤2 人選項直接 disable。
                            onSelected: (n <= 2 && reliability.isNewUser)
                                ? null
                                : (_) => setState(() => _selectedHeadcount = n),
                          ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: AppSpacing.lg),
              Text('4. 人數不夠時，接受少一點人也算成局？', style: Theme.of(context).textTheme.titleMedium),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _allowDowngrade,
                onChanged: (v) => setState(() => _allowDowngrade = v),
                title: const Text('允許人數調整'),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppButton(label: '送出，開始找人', loading: _submitting, onPressed: _submit),
            ],
          );
        },
      ),
    );
  }
}
