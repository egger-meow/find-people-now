import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../generated/activity.dart';
import '../generated/activity_type.dart';
import '../generated/supadart_header.dart' show ACTIVITY_STATUS;
import '../rpc/activity_type_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';

/// UI_PLAN.md §2 配對頁（首頁）— 填表 → 送出 → 等待室這一條路徑。
/// §7 時段桶 UI：方向已定案（5 個固定時段桶＋「現在」快速選項、僅顯示
/// now()~now()+24h 內的桶、多選收斂成單一連續區間、可切換詳細時間模式），
/// 這裡是第一版實作——`create_request` 早已直接收 `p_earliest_start`/
/// `p_latest_start` 原始時間戳（v1.16），這裡的桶邏輯只是前端換算，不影響
/// RPC 呼叫本身。
///
/// 反饋：原本 5 個標號區塊（選類型/選時段/選校區/選人數/降級開關）視覺density
/// 太高，「像在填 Google Form」。改成卡片式、更快決策的排版——校區在 MVP
/// 單校區假設下（見 match_providers.dart 的 [campusOptionsProvider] 註解）
/// 只有一個選項時直接顯示，不再讓使用者多一步選擇。
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
            icon: const Icon(Icons.link_rounded),
            tooltip: '輸入邀請碼加入房間',
            onPressed: () => _showJoinByTokenDialog(context, ref),
          ),
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
            if (request != null) {
              // UI_PLAN §2.2 送出前預先攔截 — 還在找人流程中（REQUESTING/
              // PENDING_CONFIRMATION）的 Request 就直接導去等待室，不重新
              // 顯示表單。用 post-frame callback 避免在 build 中途觸發導覽。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) context.push('/waiting-room/${request.id}');
              });
              return const LoadingIndicator(label: '你已經有進行中的配對，正在帶你過去…');
            }
            // 反饋：使用者目前有 MATCHED/ONGOING 活動時，配對頁該直接告知
            // 「當前有活動，無法建立新配對」，而不是讓使用者填完整張表單才在
            // 送出當下收到 ACTIVE_ACTIVITY_IN_PROGRESS 錯誤（見
            // match_providers.dart 的 [myActiveActivityProvider] 註解）。
            final activeActivity = ref.watch(myActiveActivityProvider);
            return activeActivity.when(
              loading: () => const LoadingIndicator(),
              error: (error, stack) => Center(child: Text('載入失敗：$error')),
              data: (activity) {
                if (activity != null) {
                  return _ActiveActivityBlock(activity: activity);
                }
                return const _CreateRequestForm();
              },
            );
          },
        ),
      ),
    );
  }

  /// 反饋：配對頁沒有以邀請碼加入房間的入口。
  /// UI_PLAN §3 提到「邀請朋友」按鈕產生連結/邀請碼，但收到邀請碼的人需要
  /// 一個地方輸入——這裡在配對頁提供入口，呼叫 `join_request_by_token` RPC。
  static Future<void> _showJoinByTokenDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? errorText;

    Future<void> attemptJoin(BuildContext dialogContext, StateSetter setDialogState) async {
      final token = controller.text.trim();
      if (token.isEmpty) {
        setDialogState(() => errorText = '請輸入邀請碼');
        return;
      }
      try {
        final request = await joinRequestByToken(ref.read(supabaseClientProvider), token);
        if (!dialogContext.mounted) return;
        Navigator.of(dialogContext).pop(true);
        if (context.mounted) context.push('/waiting-room/${request.id}');
      } on ApiException catch (e) {
        final message = switch (e.code) {
          ApiErrorCode.inviteLinkExpired => '邀請碼不存在或已失效，請向朋友要一個新的',
          ApiErrorCode.requestFull => '這個房間已經滿了',
          ApiErrorCode.alreadyRequesting => '你已經有進行中的配對了',
          _ => '加入失敗：${e.code.name}',
        };
        setDialogState(() => errorText = message);
      }
    }

    final joined = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('輸入邀請碼'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('把朋友分享給你的邀請碼貼在這裡，就可以加入他們的房間。'),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: controller,
                label: '邀請碼',
                hint: '貼上邀請碼',
                autofocus: true,
                errorText: errorText,
                onSubmitted: (_) => attemptJoin(dialogContext, setDialogState),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => attemptJoin(dialogContext, setDialogState),
              child: const Text('加入'),
            ),
          ],
        ),
      ),
    );
    if (joined == true) {
      // Invalidate active request so next time the screen rebuilds, it
      // picks up the new membership.
      ref.invalidate(myActiveRequestProvider);
    }
  }
}

/// 反饋：「如果有活動 active 或成立，配對頁直接灰掉，寫當前有活動，使用者
/// 無法建立新活動」——取代原本「已經有活動就整頁自動導走」的做法，改成配對頁
/// 本身顯示明確、不可互動的狀態卡，並提供前往該活動的入口。
class _ActiveActivityBlock extends StatelessWidget {
  const _ActiveActivityBlock({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusLabel = activity.status == ACTIVITY_STATUS.ONGOING ? '進行中' : '已成團，等待開始';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy_rounded, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('你目前有進行中的活動', style: textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '狀態：$statusLabel — 活動結束前無法建立新配對',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: '前往這個活動',
              onPressed: () => context.push('/activity/${activity.id}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// UI_PLAN.md §7 — 5 個固定時段桶，跨午夜的桶（晚上 20-24）`end` 落在隔天
/// 00:00。桶本身跟日期無關，實際 [DateTime] 由 [_generateBuckets] 依「今天」
/// 「明天」兩個候選日展開。
const _bucketDefs = [
  ('早上', 6, 12, Icons.wb_twilight_rounded),
  ('中午', 12, 14, Icons.wb_sunny_rounded),
  ('下午', 14, 18, Icons.light_mode_rounded),
  ('傍晚', 18, 20, Icons.brightness_4_rounded),
  ('晚上', 20, 24, Icons.nightlight_round),
];

class _TimeBucket {
  _TimeBucket({
    required this.label,
    required this.start,
    required this.end,
    required this.isTomorrow,
    required this.icon,
  });

  final String label;
  final DateTime start;
  final DateTime end;
  final bool isTomorrow;
  final IconData icon;

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
      final (label, startHour, endHour, icon) = def;
      final start = DateTime(day.year, day.month, day.day, startHour);
      final end = endHour == 24
          ? DateTime(day.year, day.month, day.day).add(const Duration(days: 1))
          : DateTime(day.year, day.month, day.day, endHour);
      if (!start.isBefore(now) && start.isBefore(windowEnd)) {
        buckets.add(_TimeBucket(label: label, start: start, end: end, isTomorrow: dayOffset == 1, icon: icon));
      }
    }
  }
  return buckets;
}

String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 活動類型沒有 icon 欄位（純文字、使用者可提案新增，見 SPEC §…propose_activity_type），
/// 這裡用關鍵字比對給常見類型一個圖示，比純文字卡片更有「App」感；比對不到
/// 就用通用的 [Icons.groups_rounded]，不影響任何未來新增的類型能不能選。
IconData _activityTypeIcon(String name) {
  final n = name.toLowerCase();
  const table = <String, IconData>{
    '籃球': Icons.sports_basketball_rounded,
    '排球': Icons.sports_volleyball_rounded,
    '羽球': Icons.sports_tennis_rounded,
    '網球': Icons.sports_tennis_rounded,
    '桌球': Icons.sports_tennis_rounded,
    '足球': Icons.sports_soccer_rounded,
    '棒球': Icons.sports_baseball_rounded,
    '咖啡': Icons.local_cafe_rounded,
    '散步': Icons.directions_walk_rounded,
    '慢跑': Icons.directions_run_rounded,
    '跑步': Icons.directions_run_rounded,
    '讀書': Icons.menu_book_rounded,
    '唸書': Icons.menu_book_rounded,
    '自習': Icons.menu_book_rounded,
    '健身': Icons.fitness_center_rounded,
    '重訓': Icons.fitness_center_rounded,
    '桌遊': Icons.casino_rounded,
    '遊戲': Icons.sports_esports_rounded,
    '電影': Icons.movie_rounded,
    '唱歌': Icons.mic_rounded,
    'ktv': Icons.mic_rounded,
    '腳踏車': Icons.directions_bike_rounded,
    '單車': Icons.directions_bike_rounded,
    '吃飯': Icons.restaurant_rounded,
    '晚餐': Icons.restaurant_rounded,
    '午餐': Icons.restaurant_rounded,
    '早餐': Icons.free_breakfast_rounded,
    '逛街': Icons.storefront_rounded,
    '爬山': Icons.terrain_rounded,
    '游泳': Icons.pool_rounded,
  };
  for (final entry in table.entries) {
    if (n.contains(entry.key)) return entry.value;
  }
  return Icons.groups_rounded;
}

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

  @override
  Widget build(BuildContext context) {
    final typesAsync = ref.watch(activityTypesProvider);
    final userAsync = ref.watch(myAppUserProvider);
    final reliabilityAsync = ref.watch(myReliabilityProvider);
    final textTheme = Theme.of(context).textTheme;

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
              Text('今天想找人一起做什麼？',
                  style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: AppSpacing.md),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 1.6,
                children: [
                  for (final type in types)
                    _OptionCard(
                      icon: _activityTypeIcon(type.name),
                      label: type.name,
                      selected: _selectedType?.id == type.id,
                      onTap: () => setState(() {
                        _selectedType = type;
                        _selectedMinHeadcount = null;
                        _selectedMaxHeadcount = null;
                      }),
                    ),
                  _AddOptionCard(label: '提議新增', onTap: _proposeActivityType),
                ],
              ),
              if (_selectedType?.description != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_selectedType!.description!, style: textTheme.bodySmall),
              ],
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('什麼時候？', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
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
                    _TimeChip(
                      icon: Icons.flash_on_rounded,
                      label: '現在',
                      selected: _nowSelected,
                      onTap: _selectNow,
                    ),
                    for (var i = 0; i < _buckets.length; i++)
                      _TimeChip(
                        icon: _buckets[i].icon,
                        label: _buckets[i].displayLabel,
                        selected: _selectedBucketIndices.contains(i),
                        onTap: () => _toggleBucket(i),
                      ),
                  ],
                ),
              ],
              if (window != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '已選範圍：${_formatTime(window.$1)} - ${_formatTime(window.$2)}'
                  '${window.$2.day != window.$1.day ? '（跨日）' : ''}',
                  style: textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              campusAsync.when(
                loading: () => const LoadingIndicator(),
                error: (error, stack) => Text('載入校區失敗：$error'),
                data: (campuses) {
                  if (campuses.isEmpty) {
                    return Text('這個學校目前還沒有已核准的地點，請聯絡管理員',
                        style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error));
                  }
                  if (_selectedCampus == null || !campuses.contains(_selectedCampus)) {
                    _selectedCampus = campuses.first;
                  }
                  // MVP 單校區假設（見 campusOptionsProvider 註解）：只有一個
                  // 選項時直接帶入顯示，不再讓使用者多一步選擇；反饋：地點清單
                  // 不該把測試/內部資料攤在使用者面前，這裡也不再列出任何原始
                  // 地點名稱，只顯示校區。
                  if (campuses.length == 1) {
                    return Row(
                      children: [
                        Icon(Icons.location_on_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            '校區：${campuses.first}',
                            style: textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('去哪個校區？', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.sm,
                        children: [
                          for (final campus in campuses)
                            _TimeChip(
                              icon: Icons.location_on_rounded,
                              label: campus,
                              selected: _selectedCampus == campus,
                              onTap: () => setState(() => _selectedCampus = campus),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('找幾個人？', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: AppSpacing.sm),
              if (_selectedType == null)
                Text('請先選活動類型', style: textTheme.bodySmall)
              else
                reliabilityAsync.when(
                  loading: () => const LoadingIndicator(),
                  error: (error, stack) => Text('載入可信度失敗：$error'),
                  data: (reliability) {
                    final options = _groupSizeOptions(_selectedType!);
                    return AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('至少', style: textTheme.bodySmall),
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
                          Text('至多', style: textTheme.bodySmall),
                          const SizedBox(height: AppSpacing.xs),
                          if (_selectedMinHeadcount == null)
                            Text('請先選「至少」人數', style: textTheme.bodySmall)
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
                      ),
                    );
                  },
                ),
              const SizedBox(height: AppSpacing.lg),
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowDowngrade,
                  onChanged: (v) => setState(() => _allowDowngrade = v),
                  title: const Text('人數不夠時，接受少一點人也算成局？'),
                ),
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

/// 選擇型大卡片——活動類型步驟用，比 [ChoiceChip] 更大的觸控面積跟視覺重量，
/// 呼應「像 Tinder / Uber 那種快速決策」的反饋。
class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: selected ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 活動類型格子最後一格：虛線邊框的「提議新增」入口，取代原本另外一行的
/// 文字連結——跟其他選項並排在同一個 grid 裡，密度感一致。
class _AddOptionCard extends StatelessWidget {
  const _AddOptionCard({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: scheme.outlineVariant, style: BorderStyle.solid),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 28, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.xs),
              Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 時段／校區步驟用的較小型選擇卡——維持多選/單選皆可的既有互動邏輯，只是
/// 從純文字 [ChoiceChip] 換成帶 icon 的版本。
class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
