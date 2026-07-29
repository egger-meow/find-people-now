import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../generated/activity_type.dart';
import '../generated/supadart_header.dart' show REQUEST_STATUS, SCHOOL;
import '../rpc/activity_type_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/location_rpc.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';

/// UI_PLAN.md §2 配對頁（首頁）— 填表 → 送出 → 等待室這一條路徑。
/// §7 時段桶 UI：方向已定案（5 個固定時段桶＋「現在」快速選項、僅顯示
/// now()~now()+24h 內的桶、多選收斂成單一連續區間、可切換詳細時間模式），
/// 這裡是第一版實作——`create_request` 早已直接收 `p_earliest_start`/
/// `p_latest_start` 原始時間戳（v1.16），這裡的桶邏輯只是前端換算，不影響
/// RPC 呼叫本身。
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
            icon: const Icon(Icons.help_outline_rounded),
            tooltip: '使用說明',
            onPressed: () => context.push('/help'),
          ),
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
                if (context.mounted) context.push('/waiting-room/${request.id}');
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

/// UI_PLAN.md §7 — 5 個固定時段桶，跨午夜的桶（晚上 20-24）`end` 落在隔天
/// 00:00。桶本身跟日期無關，實際 [DateTime] 由 [_generateBuckets] 依「今天」
/// 「明天」兩個候選日展開。
const _bucketDefs = [
  ('早上', 6, 12),
  ('中午', 12, 14),
  ('下午', 14, 18),
  ('傍晚', 18, 20),
  ('晚上', 20, 24),
];

class _TimeBucket {
  _TimeBucket({required this.label, required this.start, required this.end, required this.isTomorrow});

  final String label;
  final DateTime start;
  final DateTime end;
  final bool isTomorrow;

  String get displayLabel => isTomorrow ? '明天 $label' : label;
}

/// 動態顯示規則（UI_PLAN §7）：僅列出「起始時間」落在 `now()~now()+24h`
/// 內的桶——今天已經開始（起始時間已過去）的桶不顯示，即使桶本身還沒結束；
/// 跨到隔天範圍的桶帶「明天」前綴。
List<_TimeBucket> _generateBuckets(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final windowEnd = now.add(const Duration(hours: 24));
  final buckets = <_TimeBucket>[];
  for (final dayOffset in [0, 1]) {
    final day = today.add(Duration(days: dayOffset));
    for (final def in _bucketDefs) {
      final (label, startHour, endHour) = def;
      final start = DateTime(day.year, day.month, day.day, startHour);
      final end = endHour == 24
          ? DateTime(day.year, day.month, day.day).add(const Duration(days: 1))
          : DateTime(day.year, day.month, day.day, endHour);
      if (!start.isBefore(now) && start.isBefore(windowEnd)) {
        buckets.add(_TimeBucket(label: label, start: start, end: end, isTomorrow: dayOffset == 1));
      }
    }
  }
  return buckets;
}

String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _CreateRequestForm extends ConsumerStatefulWidget {
  const _CreateRequestForm();

  @override
  ConsumerState<_CreateRequestForm> createState() => _CreateRequestFormState();
}

class _CreateRequestFormState extends ConsumerState<_CreateRequestForm> {
  ActivityType? _selectedType;
  String? _selectedCampus;
  // UI_PLAN.md §2.1 步驟 4：人數是「接受範圍」（min~max），不是單一數字——
  // create_request RPC 本來就吃 min/max 兩個參數（docs/API.md §3.1），先前這裡
  // 只收單一數字塞進 minParticipants、maxParticipants 永遠傳 null，跟規格不符
  // （反饋：「人數不是選接受範圍嗎 怎麼變選一個數字」）。
  int? _selectedMinHeadcount;
  int? _selectedMaxHeadcount;
  bool _allowDowngrade = false;
  bool _submitting = false;
  String? _error;

  late final List<_TimeBucket> _buckets = _generateBuckets(DateTime.now());
  final Set<int> _selectedBucketIndices = {};
  bool _nowSelected = false;
  bool _detailedMode = false;
  DateTime? _customEarliest;
  DateTime? _customLatest;

  List<int> _groupSizeOptions(ActivityType type) {
    final min = type.defaultMinParticipants ?? 2;
    final max = type.defaultMaxParticipants ?? min;
    final step = (type.groupSizeStep != null && type.groupSizeStep! > 0) ? type.groupSizeStep! : 1;
    return [for (var v = min; v <= max; v += step) v];
  }

  void _toggleBucket(int index) {
    setState(() {
      _nowSelected = false;
      if (_selectedBucketIndices.contains(index)) {
        _selectedBucketIndices.remove(index);
      } else {
        _selectedBucketIndices.add(index);
      }
    });
  }

  void _selectNow() {
    setState(() {
      _nowSelected = true;
      _selectedBucketIndices.clear();
    });
  }

  Future<void> _pickCustomTime({required bool isEarliest}) async {
    final now = DateTime.now();
    final initial = (isEarliest ? _customEarliest : _customLatest) ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(hours: 24)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      _nowSelected = false;
      _selectedBucketIndices.clear();
      if (isEarliest) {
        _customEarliest = picked;
      } else {
        _customLatest = picked;
      }
    });
  }

  /// 「多選收斂為單一連續區間」（UI_PLAN §7）：取所選桶中最早的起始～最晚的
  /// 結束，即使中間有沒選到的桶也一樣收斂成一段連續時間。
  (DateTime, DateTime)? _resolveWindow() {
    final now = DateTime.now();
    if (_nowSelected) {
      return (now, now.add(const Duration(minutes: 30)));
    }
    if (_detailedMode) {
      if (_customEarliest == null || _customLatest == null) return null;
      return (_customEarliest!, _customLatest!);
    }
    if (_selectedBucketIndices.isEmpty) return null;
    final selected = _selectedBucketIndices.map((i) => _buckets[i]).toList();
    final earliest = selected.map((b) => b.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final latest = selected.map((b) => b.end).reduce((a, b) => a.isAfter(b) ? a : b);
    // 防呆夾在 now()+24h 內——正常情況下桶本身已經過濾過，這裡只防呼叫
    // 這支函式的當下距離畫面產生桶清單的當下已經過了一段時間的邊界誤差。
    final cap = now.add(const Duration(hours: 24));
    return (earliest, latest.isAfter(cap) ? cap : latest);
  }

  Future<void> _submit() async {
    final type = _selectedType;
    final campus = _selectedCampus;
    final min = _selectedMinHeadcount;
    final max = _selectedMaxHeadcount;
    final window = _resolveWindow();
    if (type == null || campus == null || min == null || max == null || window == null) {
      setState(() => _error = '請完成所有選擇');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final client = ref.read(supabaseClientProvider);
    try {
      final (earliest, latest) = window;
      final request = await createRequest(
        client,
        activityTypeId: type.id,
        campus: campus,
        earliestStart: earliest.toUtc(),
        latestStart: latest.toUtc(),
        minParticipants: min,
        maxParticipants: max,
        allowDowngrade: _allowDowngrade,
      );
      await submitRequest(client, request.id);
      if (!mounted) return;
      context.push('/waiting-room/${request.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗：${e.code.name}${e.detail != null ? '（${e.detail}）' : ''}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 反饋：現有活動類型只有官方預設的固定清單可選，使用者想新增卻找不到入口
  /// ——後端其實早就有 `propose_activity_type` RPC（PENDING → admin 審核，比照
  /// `search_activity_type` 只回傳 `status='APPROVED'`，見
  /// `20260724120250_rpc_activity_type_and_location.sql`），只是從沒被任何畫面
  /// 呼叫過。這裡補上入口——送出後不會馬上出現在清單裡（還在審核中），所以
  /// 明確告知使用者這一輪先照現有類型選，等審核過再回來選新的。
  Future<void> _proposeActivityType() async {
    final controller = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('提議新活動類型'),
        content: AppTextField(controller: controller, label: '類型名稱', autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('送出')),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;

    final client = ref.read(supabaseClientProvider);
    try {
      await proposeActivityType(client, name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已送出「$name」，審核通過後才會出現在清單中')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.duplicateTypeName ? '這個類型已經存在了' : '送出失敗：${e.code.name}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 反饋：地點跟活動類型一樣——`propose_location` RPC 早就存在（PENDING →
  /// admin 審核），但沒有任何畫面呼叫過。地點的 catalog 是 (school, campus,
  /// name) 三元組，`school` 直接用使用者自己的學校，不用讓使用者重選。
  Future<void> _proposeLocation(SCHOOL school) async {
    final nameController = TextEditingController();
    final campusController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('提議新地點'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(controller: nameController, label: '地點名稱', autofocus: true),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: campusController, label: '校區（例如：光復）'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('送出')),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final name = nameController.text.trim();
    final campus = campusController.text.trim();
    if (name.isEmpty || campus.isEmpty) return;

    final client = ref.read(supabaseClientProvider);
    try {
      await proposeLocation(client, name: name, school: school, campus: campus);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已送出「$name」，審核通過後才會出現在清單中')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.duplicateLocationName ? '這個地點已經存在了' : '送出失敗：${e.code.name}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
          final window = _resolveWindow();

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
                        _selectedMinHeadcount = null;
                        _selectedMaxHeadcount = null;
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
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _proposeActivityType,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('沒有你要的類型？提議新增'),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('2. 選時段', style: Theme.of(context).textTheme.titleMedium),
                  TextButton(
                    onPressed: () => setState(() {
                      _detailedMode = !_detailedMode;
                      _nowSelected = false;
                      _selectedBucketIndices.clear();
                    }),
                    child: Text(_detailedMode ? '改選時段' : '自訂時間'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_detailedMode) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _pickCustomTime(isEarliest: true),
                        child: Text(_customEarliest == null ? '最早開始時間' : _formatTime(_customEarliest!)),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _pickCustomTime(isEarliest: false),
                        child: Text(_customLatest == null ? '最晚開始時間' : _formatTime(_customLatest!)),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    ChoiceChip(
                      label: const Text('現在（30 分鐘內）'),
                      selected: _nowSelected,
                      onSelected: (_) => _selectNow(),
                    ),
                    for (var i = 0; i < _buckets.length; i++)
                      ChoiceChip(
                        label: Text(_buckets[i].displayLabel),
                        selected: _selectedBucketIndices.contains(i),
                        onSelected: (_) => _toggleBucket(i),
                      ),
                  ],
                ),
              ],
              if (window != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '已選範圍：${_formatTime(window.$1)} - ${_formatTime(window.$2)}'
                  '${window.$2.day != window.$1.day ? '（跨日）' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Text('3. 選校區', style: Theme.of(context).textTheme.titleMedium),
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
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _proposeLocation(user.school),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('沒有你要的地點？提議新增'),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('4. 選人數（願意接受的範圍）', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              if (_selectedType == null)
                Text('請先選活動類型', style: Theme.of(context).textTheme.bodySmall)
              else
                reliabilityAsync.when(
                  loading: () => const LoadingIndicator(),
                  error: (error, stack) => Text('載入可信度失敗：$error'),
                  data: (reliability) {
                    final options = _groupSizeOptions(_selectedType!);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('至少', style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.sm,
                          children: [
                            for (final n in options)
                              ChoiceChip(
                                label: Text('$n 人'),
                                selected: _selectedMinHeadcount == n,
                                // UI_PLAN §2.2：New tier 使用者 ≤2 人選項直接 disable。
                                onSelected: (n <= 2 && reliability.isNewUser)
                                    ? null
                                    : (_) => setState(() {
                                          _selectedMinHeadcount = n;
                                          // 最多不能小於最少——若原本選的最多比新的
                                          // 最少還小，直接清掉讓使用者重選。
                                          if (_selectedMaxHeadcount != null && _selectedMaxHeadcount! < n) {
                                            _selectedMaxHeadcount = null;
                                          }
                                        }),
                              ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text('至多', style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpacing.xs),
                        if (_selectedMinHeadcount == null)
                          Text('請先選「至少」人數', style: Theme.of(context).textTheme.bodySmall)
                        else
                          Wrap(
                            spacing: AppSpacing.sm,
                            children: [
                              for (final n in options)
                                if (n >= _selectedMinHeadcount!)
                                  ChoiceChip(
                                    label: Text('$n 人'),
                                    selected: _selectedMaxHeadcount == n,
                                    onSelected: (_) => setState(() => _selectedMaxHeadcount = n),
                                  ),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: AppSpacing.lg),
              Text('5. 人數不夠時，接受少一點人也算成局？', style: Theme.of(context).textTheme.titleMedium),
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
