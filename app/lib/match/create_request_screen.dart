import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../data/activity_type_icons.dart';
import '../data/sport_level_config.dart';
import '../errors/user_error_message.dart';
import '../generated/activity.dart';
import '../generated/activity_type.dart';
import '../generated/app_user.dart';
import '../generated/match_request.dart';
import '../generated/supadart_header.dart' show SCHOOL;
import '../rpc/activity_type_rpc.dart';
import '../rpc/alert_subscription_rpc.dart';
import '../rpc/api_exception.dart';
import '../rpc/campus_demand_rpc.dart';
import '../rpc/match_request_rpc.dart';
import '../theme/app_haptics.dart';
import '../theme/app_theme.dart';
import '../theme/platform_adaptive.dart';
import '../widgets/app_button.dart';
import '../widgets/app_error_state.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_section.dart';
import '../widgets/app_selection_summary.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_sticky_action_area.dart';
import '../widgets/app_text_field.dart';
import '../widgets/countdown_text.dart';
import '../widgets/loading_indicator.dart';
import 'match_providers.dart';
import 'widgets/activity_demand_detail_sheet.dart';
import 'widgets/campus_demands_section.dart';
import 'widgets/pinned_active_status_card.dart';

/// Submission boundary for the create-request journey. Production uses the
/// existing RPC wrappers; widget tests can replace only this boundary while
/// still exercising the real screen state, confirmation, invalidation, and
/// navigation flow.
abstract interface class MatchRequestSubmissionGateway {
  const MatchRequestSubmissionGateway();

  MatchRequestSubmissionSession capture(WidgetRef ref);
}

abstract interface class MatchRequestSubmissionSession {
  const MatchRequestSubmissionSession();

  Future<MatchRequest> create({
    required String activityTypeId,
    required String campus,
    required DateTime earliestStart,
    required DateTime latestStart,
    required int minParticipants,
    required int maxParticipants,
    required bool allowDowngrade,
    required String? sportLevel,
    int? sportLevelRating,
    required String? studyTarget,
  });

  Future<MatchRequest> submit(String requestId);
}

class RpcMatchRequestSubmissionGateway
    implements MatchRequestSubmissionGateway {
  const RpcMatchRequestSubmissionGateway();

  @override
  MatchRequestSubmissionSession capture(WidgetRef ref) {
    return _RpcMatchRequestSubmissionSession(ref.read(supabaseClientProvider));
  }
}

class _RpcMatchRequestSubmissionSession
    implements MatchRequestSubmissionSession {
  const _RpcMatchRequestSubmissionSession(this.client);

  final SupabaseClient client;

  @override
  Future<MatchRequest> create({
    required String activityTypeId,
    required String campus,
    required DateTime earliestStart,
    required DateTime latestStart,
    required int minParticipants,
    required int maxParticipants,
    required bool allowDowngrade,
    required String? sportLevel,
    int? sportLevelRating,
    required String? studyTarget,
  }) {
    return createRequest(
      client,
      activityTypeId: activityTypeId,
      campus: campus,
      earliestStart: earliestStart,
      latestStart: latestStart,
      minParticipants: minParticipants,
      maxParticipants: maxParticipants,
      allowDowngrade: allowDowngrade,
      sportLevel: sportLevel,
      sportLevelRating: sportLevelRating,
      studyTarget: studyTarget,
    );
  }

  @override
  Future<MatchRequest> submit(String requestId) {
    return submitRequest(client, requestId);
  }
}

DateTime _systemNow() => DateTime.now();

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
  const CreateRequestScreen({
    super.key,
    this.submissionGateway = const RpcMatchRequestSubmissionGateway(),
    this.now = _systemNow,
  });

  final MatchRequestSubmissionGateway submissionGateway;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // [AppStickyActionArea] consumes viewInsets itself so the action and the
      // remaining scrollable form move together above the keyboard. Letting
      // Scaffold also resize the body would count the keyboard height twice.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('敢不敢揪'),
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
        ],
      ),
      body: SafeArea(
        child: _CreateRequestForm(
          submissionGateway: submissionGateway,
          now: now,
        ),
      ),
    );
  }

  /// 反饋：配對頁沒有以邀請碼加入房間的入口。
  /// UI_PLAN §3 提到「邀請朋友」按鈕產生連結/邀請碼，但收到邀請碼的人需要
  /// 一個地方輸入——這裡在配對頁提供入口，呼叫 `join_request_by_token` RPC。
  static Future<void> _showJoinByTokenDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final controller = TextEditingController();
    String? errorText;

    Future<void> attemptJoin(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      final token = controller.text.trim();
      if (token.isEmpty) {
        setDialogState(() => errorText = '請輸入邀請碼');
        return;
      }
      try {
        final request = await joinRequestByToken(
          ref.read(supabaseClientProvider),
          token,
        );
        if (!dialogContext.mounted) return;
        Navigator.of(dialogContext).pop(true);
        if (context.mounted) context.push('/waiting-room/${request.id}');
      } on ApiException catch (e) {
        final message = switch (e.code) {
          ApiErrorCode.inviteLinkExpired => '邀請碼不存在或已失效，請向朋友要一個新的',
          ApiErrorCode.requestFull => '這個房間已經滿了',
          ApiErrorCode.alreadyRequesting => '你已經有進行中的配對了',
          _ => userErrorMessage(e),
        };
        setDialogState(() => errorText = message);
      }
    }

    final joined = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AppAdaptiveDialog(
          title: '輸入邀請碼',
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
            AppDialogAction(
              label: '取消',
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            AppDialogAction(
              label: '加入',
              isDefault: true,
              onPressed: () => attemptJoin(dialogContext, setDialogState),
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
        buckets.add(
          _TimeBucket(
            label: label,
            start: start,
            end: end,
            isTomorrow: dayOffset == 1,
            icon: icon,
          ),
        );
      }
    }
  }
  return buckets;
}

String _formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Formats the complete time criterion used by both the persistent summary and
/// the confirmation snapshot. [relativeTo] keeps tomorrow/date behavior
/// deterministic in regression tests.
String formatMatchRequestWindow(
  (DateTime, DateTime)? window, {
  DateTime? relativeTo,
}) {
  if (window == null) return '尚未選擇';
  final now = relativeTo ?? DateTime.now();
  String dateLabel(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = date.difference(today).inDays;
    if (difference == 0) return '今天';
    if (difference == 1) return '明天';
    return '${value.month} 月 ${value.day} 日';
  }

  final startLabel = '${dateLabel(window.$1)} ${_formatTime(window.$1)}';
  if (window.$1.year == window.$2.year &&
      window.$1.month == window.$2.month &&
      window.$1.day == window.$2.day) {
    return '$startLabel - ${_formatTime(window.$2)}';
  }
  return '$startLabel - ${dateLabel(window.$2)} ${_formatTime(window.$2)}';
}

/// Alert Subscription（v1.27）——「羽球在光復校區 3 小時內出現就通知我」。
/// 顯示目前有效的訂閱（可取消）+ 一個開新訂閱的入口。
Future<void> _showSubscribeAlertDialog({
  required BuildContext context,
  required WidgetRef ref,
  required SCHOOL school,
  required String campus,
  required List<ActivityType> types,
}) async {
  if (types.isEmpty) return;
  ActivityType selectedType = types.first;
  int hours = 3;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AppAdaptiveDialog(
        title: '設定提醒',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '活動類型',
              style: Theme.of(dialogContext).textTheme.labelMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            DropdownButton<ActivityType>(
              isExpanded: true,
              value: selectedType,
              items: [
                for (final type in types)
                  DropdownMenuItem(value: type, child: Text(type.name)),
              ],
              onChanged: (value) {
                if (value != null) setDialogState(() => selectedType = value);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '$campus 出現在幾小時內就通知我',
              style: Theme.of(dialogContext).textTheme.labelMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (final option in const [1, 3, 6, 12, 24])
                  ChoiceChip(
                    label: Text('$option 小時'),
                    selected: hours == option,
                    onSelected: AppHaptics.select(
                      (_) => setDialogState(() => hours = option),
                    ),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          AppDialogAction(
            label: '取消',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppDialogAction(
            label: '設定提醒',
            isDefault: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;

  try {
    await subscribeActivityAlert(
      ref.read(supabaseClientProvider),
      activityTypeId: selectedType.id,
      school: school,
      campus: campus,
      lookaheadHours: hours,
    );
    ref.invalidate(myActiveAlertSubscriptionsProvider);
  } on ApiException catch (e) {
    if (!context.mounted) return;
    final message = e.code == ApiErrorCode.tooManyAlertSubscriptions
        ? '同時最多只能設定 5 個提醒，先取消一些吧'
        : userErrorMessage(e);
    showAppSnackBar(context, message, kind: AppSnackKind.error);
  }
}

class _AlertSubscriptionSection extends ConsumerWidget {
  const _AlertSubscriptionSection({
    required this.school,
    required this.campus,
    required this.types,
  });

  final SCHOOL school;
  final String campus;
  final List<ActivityType> types;

  Future<void> _cancel(WidgetRef ref, String subscriptionId) async {
    await unsubscribeActivityAlert(
      ref.read(supabaseClientProvider),
      subscriptionId: subscriptionId,
    );
    ref.invalidate(myActiveAlertSubscriptionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subsAsync = ref.watch(myActiveAlertSubscriptionsProvider);
    final subs = subsAsync.value ?? const [];
    final typeNameById = {for (final type in types) type.id: type.name};

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_active_outlined, size: 18),
              const SizedBox(width: AppSpacing.xs),
              const Expanded(child: Text('沒等到想要的活動？設定提醒，出現就通知你')),
              TextButton(
                onPressed: () => _showSubscribeAlertDialog(
                  context: context,
                  ref: ref,
                  school: school,
                  campus: campus,
                  types: types,
                ),
                child: const Text('設定'),
              ),
            ],
          ),
          if (subs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final sub in subs)
                  InputChip(
                    label: Text(typeNameById[sub.activityTypeId] ?? '未知類型'),
                    onDeleted: () => _cancel(ref, sub.id),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 讀書「同伴目標」熱門科目下拉（v1.35）——目前是合理猜測的通識/必修科目
/// 佔位清單，之後再依實際選課資料調整。純粹是輔助輸入，選了就是把文字帶進
/// 下面的自由輸入框，不是獨立的資料類型。
const _popularStudySubjects = [
  '微積分',
  '普通物理',
  '線性代數',
  '演算法',
  '離散數學',
  '機率統計',
  '作業系統',
  '電路學',
  '經濟學',
  '會計學',
];

/// 鏡射 `fn_normalize_study_target`
/// (supabase/migrations/20260803160200_study_target_schema.sql) 的正規化規則
/// ——純粹是即時預覽用，實際比對值仍由後端 RPC 重新計算，這裡兩邊邏輯必須
/// 保持一致才不會讓使用者看到的預覽跟後端實際儲存/比對的結果不一樣。
///
/// 順序刻意跟 SQL 版一致：先把全形括號/全形空白轉成半形，再裁頭尾空白、轉
/// 小寫——如果先裁再轉，剛好卡在頭尾的全形空白會因為裁切階段還不認得它是
/// 空白而被跳過，轉換後反而留下裁不掉的殘留空白（該檔案內有詳細說明）。
String? _normalizeStudyTargetPreview(String input) {
  final converted = input
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('　', ' ');
  final normalized = converted.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

class _RequestSubmissionSnapshot {
  const _RequestSubmissionSnapshot({
    required this.type,
    required this.campus,
    required this.minParticipants,
    required this.maxParticipants,
    required this.window,
    required this.allowDowngrade,
    required this.sportLevel,
    this.sportLevelRating,
    required this.studyTarget,
  });

  final ActivityType type;
  final String campus;
  final int minParticipants;
  final int maxParticipants;
  final (DateTime, DateTime) window;
  final bool allowDowngrade;
  final String? sportLevel;
  final int? sportLevelRating;
  final String? studyTarget;
}

class _CreateRequestForm extends ConsumerStatefulWidget {
  const _CreateRequestForm({
    required this.submissionGateway,
    required this.now,
  });

  final MatchRequestSubmissionGateway submissionGateway;
  final DateTime Function() now;

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
  bool _confirming = false;
  String? _error;

  // v1.42 — 運動專屬強度/實力/NTRP 等級與選填積分
  String? _selectedSportLevel;
  final _ratingController = TextEditingController();
  final _studyTargetController = TextEditingController();

  late final List<_TimeBucket> _buckets;
  final Set<int> _selectedBucketIndices = {};
  bool _nowSelected = false;
  bool _detailedMode = false;
  DateTime? _customEarliest;
  DateTime? _customLatest;

  // 反饋：「選完一個項目會自然滑到下一個要選的東西標題」——每個步驟選完後，
  // 自動把畫面捲到下一步的標題，減少使用者自己往下滑找下一步的摩擦。只在
  // 「從未選到已選」這個轉換點觸發一次，避免多選的時段桶每次切換都跳動。
  // 若選擇的活動類型附帶二級參數（例如運動強度/實力/NTRP、讀書科目），
  // 則先捲動聚焦到二級參數區塊，待填妥後再前進至時間區塊。
  final _activityParamsKey = GlobalKey();
  final _formTopKey = GlobalKey();
  final _timeSectionKey = GlobalKey();
  final _campusSectionKey = GlobalKey();
  final _headcountSectionKey = GlobalKey();

  bool _typeHasParameters(ActivityType? type) {
    if (type == null) return false;
    return SportLevelConfig.forSystem(type.levelSystem) != null ||
        type.name == '讀書';
  }

  @override
  void initState() {
    super.initState();
    _buckets = _generateBuckets(widget.now());
  }

  @override
  void dispose() {
    _ratingController.dispose();
    _studyTargetController.dispose();
    super.dispose();
  }

  void _scrollToSection(GlobalKey key, {double? alignment = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      if (alignment != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: AppMotion.normal,
          curve: AppMotion.curve,
          alignment: alignment,
        );
      } else {
        Scrollable.ensureVisible(
          ctx,
          duration: AppMotion.normal,
          curve: AppMotion.curve,
        );
      }
    });
  }

  void _scrollToNextAfterTime() {
    final user = ref.read(myAppUserProvider).value;
    if (user == null) return;
    final campuses =
        ref.read(campusOptionsProvider(user.school)).value ?? const [];
    _scrollToSection(
      campuses.length > 1 ? _campusSectionKey : _headcountSectionKey,
    );
  }

  List<int> _groupSizeOptions(ActivityType type) {
    final min = type.defaultMinParticipants ?? 3;
    final max = type.defaultMaxParticipants ?? min;
    final step = (type.groupSizeStep != null && type.groupSizeStep! > 0)
        ? type.groupSizeStep!
        : 1;
    return [for (var v = min; v <= max; v += step) v];
  }

  void _toggleBucket(int index) {
    final wasEmpty = _resolveWindow() == null;
    setState(() {
      _nowSelected = false;
      if (_selectedBucketIndices.contains(index)) {
        _selectedBucketIndices.remove(index);
      } else {
        _selectedBucketIndices.add(index);
      }
    });
    if (wasEmpty && _resolveWindow() != null) _scrollToNextAfterTime();
  }

  void _selectNow() {
    final wasEmpty = _resolveWindow() == null;
    setState(() {
      _nowSelected = true;
      _selectedBucketIndices.clear();
    });
    if (wasEmpty) _scrollToNextAfterTime();
  }

  Future<void> _pickCustomTime({required bool isEarliest}) async {
    final now = widget.now();
    final initial = (isEarliest ? _customEarliest : _customLatest) ?? now;
    final clampedInitial = initial.isBefore(now) ? now : initial;
    final maxDate = now.add(const Duration(hours: 24));

    DateTime? picked;
    if (isCupertino) {
      picked = await _pickCupertinoDateTime(
        initial: clampedInitial,
        minDate: now,
        maxDate: maxDate,
      );
    } else {
      final date = await showDatePicker(
        context: context,
        initialDate: clampedInitial,
        firstDate: now,
        lastDate: maxDate,
      );
      if (date == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
      );
      if (time == null || !mounted) return;
      picked = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    }
    if (picked == null || !mounted) return;

    final wasEmpty = _resolveWindow() == null;
    setState(() {
      _nowSelected = false;
      _selectedBucketIndices.clear();
      if (isEarliest) {
        _customEarliest = picked;
      } else {
        _customLatest = picked;
      }
    });
    if (wasEmpty && _resolveWindow() != null) _scrollToNextAfterTime();
  }

  /// iOS 版自訂時間選擇——單一 [CupertinoDatePicker]（滾輪、日期+時間一次選）
  /// 取代 Android 兩步驟的 `showDatePicker` + `showTimePicker`，符合 HIG 慣例。
  /// 邊界跟 Android 分支完全一致：夾在 `[minDate, maxDate]`（now()~now()+24h）
  /// 內，選完才回傳，取消回傳 null。
  Future<DateTime?> _pickCupertinoDateTime({
    required DateTime initial,
    required DateTime minDate,
    required DateTime maxDate,
  }) {
    var selected = initial;
    return showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (popupContext) => Container(
        height: 300,
        color: CupertinoColors.systemBackground.resolveFrom(popupContext),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.of(popupContext).pop(),
                      child: const Text('取消'),
                    ),
                    CupertinoButton(
                      onPressed: () => Navigator.of(popupContext).pop(selected),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  initialDateTime: initial,
                  minimumDate: minDate,
                  maximumDate: maxDate,
                  use24hFormat: true,
                  onDateTimeChanged: (value) => selected = value,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「多選收斂為單一連續區間」（UI_PLAN §7）：取所選桶中最早的起始～最晚的
  /// 結束，即使中間有沒選到的桶也一樣收斂成一段連續時間。
  (DateTime, DateTime)? _resolveWindow() {
    final now = widget.now();
    if (_nowSelected) {
      return (now, now.add(const Duration(minutes: 30)));
    }
    if (_detailedMode) {
      if (_customEarliest == null || _customLatest == null) return null;
      return (_customEarliest!, _customLatest!);
    }
    if (_selectedBucketIndices.isEmpty) return null;
    final selected = _selectedBucketIndices.map((i) => _buckets[i]).toList();
    final earliest = selected
        .map((b) => b.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final latest = selected
        .map((b) => b.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    // 防呆夾在 now()+24h 內——正常情況下桶本身已經過濾過，這裡只防呼叫
    // 這支函式的當下距離畫面產生桶清單的當下已經過了一段時間的邊界誤差。
    final cap = now.add(const Duration(hours: 24));
    return (earliest, latest.isAfter(cap) ? cap : latest);
  }

  Future<void> _submit(_RequestSubmissionSnapshot snapshot) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    // WidgetRef is tied to this form's lifecycle. Capture every dependency
    // needed after an async boundary while the form is still mounted.
    final submission = widget.submissionGateway.capture(ref);
    final user = ref.read(myAppUserProvider).value;
    final defaultCampusClient =
        user != null && snapshot.campus != user.defaultCampus
        ? ref.read(supabaseClientProvider)
        : null;
    final providerContainer = ProviderScope.containerOf(context, listen: false);

    void invalidateActiveRequest() {
      try {
        providerContainer.invalidate(myActiveRequestProvider);
      } on StateError {
        // The complete ProviderScope may have been disposed while the RPC was
        // in flight. There is no surviving cache to invalidate in that case.
      }
    }

    void invalidateUser() {
      try {
        providerContainer.invalidate(myAppUserProvider);
      } on StateError {
        // See [invalidateActiveRequest].
      }
    }

    try {
      final request = await submission.create(
        activityTypeId: snapshot.type.id,
        campus: snapshot.campus,
        earliestStart: snapshot.window.$1.toUtc(),
        latestStart: snapshot.window.$2.toUtc(),
        minParticipants: snapshot.minParticipants,
        maxParticipants: snapshot.maxParticipants,
        allowDowngrade: snapshot.allowDowngrade,
        sportLevel: snapshot.sportLevel,
        sportLevelRating: snapshot.sportLevelRating,
        studyTarget: snapshot.studyTarget,
      );
      await submission.submit(request.id);
      // The request now exists and is submitted. Invalidate immediately, even
      // if this screen was removed while create was in flight, so another
      // consumer cannot keep serving the pre-submit null cache.
      invalidateActiveRequest();
      // v1.32 —「隨時可以改」：這次實際選的校區跟 default_campus 不同就回寫，
      // 下次建立揪團直接預設這裡選的（等同「上次使用的校區」）。安靜失敗——
      // 最壞情況只是下次還要重選一次，不影響本次配對送出。
      if (user != null && defaultCampusClient != null) {
        try {
          await defaultCampusClient
              .from('app_user')
              .update({'default_campus': snapshot.campus})
              .eq('id', user.id);
          invalidateUser();
        } catch (_) {}
      }
      if (!mounted) return;
      context.push('/waiting-room/${request.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorMessage(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showDemandDetailSheet({
    required BuildContext context,
    required CampusDemandCard demand,
    required AppUser user,
    required List<ActivityType> types,
    required bool hasActiveState,
    required MatchRequest? activeRequest,
    required Activity? activeActivity,
    required bool isCooldown,
  }) {
    return showActivityDemandDetailSheet(
      context,
      demand: demand,
      canParticipate: !hasActiveState && !isCooldown,
      disabledReason: activeRequest != null
          ? '你已在配對等待室中，無法同時加入其他活動'
          : (activeActivity != null
              ? '你目前有進行中的活動，活動結束前無法加入'
              : (isCooldown ? '配對冷卻中，暫時無法加入' : null)),
      relativeNow: widget.now(),
      onParticipate: () async {
        await _participateDemand(demand, types);
      },
      onCustomize: () {
        _applyDemandToForm(demand, types);
      },
    );
  }

  Future<void> _participateDemand(
    CampusDemandCard demand,
    List<ActivityType> types,
  ) async {
    final type = types.where((t) => t.id == demand.activityTypeId).firstOrNull ??
        types.where((t) => t.name == demand.activityTypeName).firstOrNull;
    if (type == null) {
      showAppSnackBar(context, '找不到對應的活動類型', kind: AppSnackKind.error);
      return;
    }

    final now = widget.now();
    final effectiveEarliest = demand.earliestStart.isBefore(now) ? now : demand.earliestStart;
    if (!effectiveEarliest.isBefore(demand.latestStart)) {
      showAppSnackBar(context, '此需求的時間區間已過期，無法加入', kind: AppSnackKind.error);
      return;
    }

    final snapshot = _RequestSubmissionSnapshot(
      type: type,
      campus: demand.campus,
      minParticipants: demand.minParticipants,
      maxParticipants: demand.maxParticipants,
      window: (effectiveEarliest, demand.latestStart),
      allowDowngrade: true,
      sportLevel: demand.sportLevel,
      sportLevelRating: demand.sportLevelRating,
      studyTarget: demand.studyTarget,
    );

    await _submit(snapshot);
  }

  void _applyDemandToForm(
    CampusDemandCard demand,
    List<ActivityType> types,
  ) {
    final type = types.where((t) => t.id == demand.activityTypeId).firstOrNull ??
        types.where((t) => t.name == demand.activityTypeName).firstOrNull;

    final now = widget.now();
    final isExpired = !now.isBefore(demand.latestStart);
    final effectiveEarliest = isExpired ? now : (demand.earliestStart.isBefore(now) ? now : demand.earliestStart);
    final effectiveLatest = isExpired ? now.add(const Duration(hours: 2)) : demand.latestStart;

    setState(() {
      if (type != null) {
        _selectedType = type;
      }
      _selectedCampus = demand.campus;
      ref.read(selectedCampusProvider.notifier).setCampus(demand.campus);
      _selectedMinHeadcount = demand.minParticipants;
      _selectedMaxHeadcount = demand.maxParticipants;
      _selectedSportLevel = demand.sportLevel;
      if (demand.sportLevelRating != null) {
        _ratingController.text = demand.sportLevelRating.toString();
      } else {
        _ratingController.clear();
      }
      if (demand.studyTarget != null && demand.studyTarget!.isNotEmpty) {
        _studyTargetController.text = demand.studyTarget!;
      } else {
        _studyTargetController.clear();
      }
      _detailedMode = true;
      _nowSelected = false;
      _selectedBucketIndices.clear();
      _customEarliest = effectiveEarliest;
      _customLatest = effectiveLatest;
    });

    _scrollToSection(_formTopKey);
    showAppSnackBar(
      context,
      isExpired
          ? '此需求的時間已過期，已為你填入預設時間與「${demand.activityTypeName}」條件'
          : '已為你預填「${demand.activityTypeName}」的條件，可自由微調後送出',
      kind: AppSnackKind.neutral,
    );
  }

  String _timeWindowLabel((DateTime, DateTime)? window) {
    return formatMatchRequestWindow(window, relativeTo: widget.now());
  }

  String? _missingRequiredChoice((DateTime, DateTime)? window) {
    if (_selectedType == null) return '請先選擇活動';
    if (window == null) return '請先選擇時間';
    if (_selectedCampus == null) return '請先選擇校區';
    if (_selectedMinHeadcount == null) return '請先選擇最少人數';
    if (_selectedMaxHeadcount == null) return '請先選擇最多人數';
    return null;
  }

  List<AppSelectionSummaryItem> _selectionSummaryItems(
    (DateTime, DateTime)? window, {
    _RequestSubmissionSnapshot? snapshot,
  }) {
    final type = snapshot?.type ?? _selectedType;
    final campus = snapshot?.campus ?? _selectedCampus;
    final minParticipants = snapshot?.minParticipants ?? _selectedMinHeadcount;
    final maxParticipants = snapshot?.maxParticipants ?? _selectedMaxHeadcount;
    final allowDowngrade = snapshot?.allowDowngrade ?? _allowDowngrade;
    final sportLevel = snapshot == null
        ? _selectedSportLevel
        : snapshot.sportLevel;
    final sportLevelRating = snapshot == null
        ? int.tryParse(_ratingController.text.trim())
        : snapshot.sportLevelRating;
    final studyTarget = snapshot == null
        ? _studyTargetController.text.trim()
        : snapshot.studyTarget?.trim() ?? '';
    final sportConfig = SportLevelConfig.forSystem(type?.levelSystem);
    final items = <AppSelectionSummaryItem>[
      AppSelectionSummaryItem(label: '活動', value: type?.name ?? '尚未選擇'),
      AppSelectionSummaryItem(label: '時間', value: _timeWindowLabel(window)),
      AppSelectionSummaryItem(label: '校區', value: campus ?? '尚未選擇'),
      AppSelectionSummaryItem(
        label: '人數',
        value: minParticipants == null || maxParticipants == null
            ? '尚未選擇'
            : '最少 $minParticipants 人，最多 $maxParticipants 人',
      ),
      if (sportConfig != null)
        AppSelectionSummaryItem(
          label: sportConfig.fieldLabel,
          value: sportConfig.formatLevel(
            sportLevel,
            rating: sportLevelRating,
          ),
        ),
      if (type?.name == '讀書')
        AppSelectionSummaryItem(
          label: '讀書條件',
          value: studyTarget.isEmpty ? '不限' : studyTarget,
        ),
      AppSelectionSummaryItem(
        label: '降級配對',
        value: allowDowngrade ? '接受' : '不接受',
      ),
    ];
    return items;
  }

  Future<void> _confirmAndSubmit() async {
    if (_confirming || _submitting) return;
    final window = _resolveWindow();
    final missing = _missingRequiredChoice(window);
    if (missing != null) {
      setState(() => _error = '請完成所有選擇：$missing');
      return;
    }

    final rating = int.tryParse(_ratingController.text.trim());
    final snapshot = _RequestSubmissionSnapshot(
      type: _selectedType!,
      campus: _selectedCampus!,
      minParticipants: _selectedMinHeadcount!,
      maxParticipants: _selectedMaxHeadcount!,
      window: window!,
      allowDowngrade: _allowDowngrade,
      sportLevel: _selectedSportLevel,
      sportLevelRating: rating,
      studyTarget: _studyTargetController.text.isEmpty
          ? null
          : _studyTargetController.text,
    );
    setState(() {
      _confirming = true;
      _error = null;
    });

    var confirmed = false;
    try {
      confirmed = await showAppConfirmDialog(
        context,
        title: '確認配對條件',
        confirmLabel: '確認送出',
        barrierDismissible: false,
        content: SingleChildScrollView(
          child: AppSelectionSummary(
            items: _selectionSummaryItems(snapshot.window, snapshot: snapshot),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (confirmed && mounted) await _submit(snapshot);
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
      builder: (dialogContext) => AppAdaptiveDialog(
        title: '提議新活動類型',
        content: AppTextField(
          controller: controller,
          label: '類型名稱',
          autofocus: true,
        ),
        actions: [
          AppDialogAction(
            label: '取消',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppDialogAction(
            label: '送出',
            isDefault: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
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
      showAppSnackBar(
        context,
        '已送出「$name」，審核通過後才會出現在清單中',
        kind: AppSnackKind.success,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.duplicateTypeName
          ? '這個類型已經存在了'
          : userErrorMessage(e);
      showAppSnackBar(context, message, kind: AppSnackKind.error);
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
      error: (error, stack) => const AppErrorState(),
      data: (types) => userAsync.when(
        loading: () => const LoadingIndicator(),
        error: (error, stack) => const AppErrorState(),
        data: (user) {
          if (user == null) return const LoadingIndicator();
          final activeRequest = ref.watch(myActiveRequestProvider).value;
          final activeActivity = ref.watch(myActiveActivityProvider).value;
          final hasActiveState = activeRequest != null || activeActivity != null;

          final globalCampus = ref.watch(selectedCampusProvider);
          final campusAsync = ref.watch(campusOptionsProvider(user.school));
          final campuses = campusAsync.value ?? const [];
          final effectiveCampus = globalCampus ??
              _selectedCampus ??
              user.defaultCampus ??
              (campuses.isNotEmpty ? campuses.first : '光復校區');

          if (_selectedCampus == null && campuses.contains(effectiveCampus)) {
            _selectedCampus = effectiveCampus;
          }

          final window = _resolveWindow();
          final isCooldown =
              user.nextRequestAllowedAt != null &&
              user.nextRequestAllowedAt!.isAfter(DateTime.now());

          return Column(
            children: [
              Expanded(
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    if (hasActiveState) ...[
                      PinnedActiveStatusCard(
                        request: activeRequest,
                        activity: activeActivity,
                        onOpenWaitingRoom: activeRequest != null
                            ? () => context.push('/waiting-room/${activeRequest.id}')
                            : null,
                        onOpenActivity: activeActivity != null
                            ? () => context.push('/activity/${activeActivity.id}')
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (isCooldown) ...[
                      AppCard(
                        child: Row(
                          children: [
                            Icon(
                              Icons.hourglass_top_rounded,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '配對冷卻中（無法建立新配對）',
                                    style: textTheme.titleSmall?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Wrap(
                                    children: [
                                      const Text('剩餘時間：'),
                                      CountdownText(
                                        deadline: user.nextRequestAllowedAt!,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        expiredLabel: '已結束，刷新頁面即可發起配對',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    CampusDemandsSection(
                      school: user.school,
                      campus: effectiveCampus,
                      availableCampuses: campuses,
                      onSelectCampus: (c) {
                        ref.read(selectedCampusProvider.notifier).setCampus(c);
                        setState(() => _selectedCampus = c);
                      },
                      onSelectDemand: (demand) => _showDemandDetailSheet(
                        context: context,
                        demand: demand,
                        user: user,
                        types: types,
                        hasActiveState: hasActiveState,
                        activeRequest: activeRequest,
                        activeActivity: activeActivity,
                        isCooldown: isCooldown,
                      ),
                      onCreateNewRequest: () => _scrollToSection(_formTopKey),
                      onSetAlert: () => _showSubscribeAlertDialog(
                        context: context,
                        ref: ref,
                        school: user.school,
                        campus: effectiveCampus,
                        types: types,
                      ),
                      canParticipate: !hasActiveState && !isCooldown,
                      disabledReason: activeRequest != null
                          ? '你已在配對等待室中，無法同時加入其他活動'
                          : (activeActivity != null
                              ? '你目前有進行中的活動，活動結束前無法加入'
                              : (isCooldown ? '配對冷卻中，暫時無法加入' : null)),
                      relativeNow: widget.now(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _AlertSubscriptionSection(
                      school: user.school,
                      campus: effectiveCampus,
                      types: types,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    KeyedSubtree(
                      key: _formTopKey,
                      child: AppSection(
                        title: '活動',
                        description: '今天想找人一起做什麼？',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GridView.count(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            crossAxisCount: 2,
                            mainAxisSpacing: AppSpacing.sm,
                            crossAxisSpacing: AppSpacing.sm,
                            mainAxisExtent:
                                72 + MediaQuery.textScalerOf(context).scale(24),
                            children: [
                              for (final type in types)
                                _OptionCard(
                                  icon: activityTypeIcon(type.name),
                                  label: type.name,
                                  selected: _selectedType?.id == type.id,
                                  onTap: () {
                                    final hasParams = _typeHasParameters(type);
                                    setState(() {
                                      _selectedType = type;
                                      _selectedMinHeadcount = null;
                                      _selectedMaxHeadcount = null;
                                      _selectedSportLevel = null;
                                      _ratingController.clear();
                                      _studyTargetController.clear();
                                    });
                                    if (hasParams) {
                                      _scrollToSection(
                                        _activityParamsKey,
                                        alignment: null,
                                      );
                                    } else {
                                      _scrollToSection(_timeSectionKey);
                                    }
                                  },
                                ),
                              _AddOptionCard(
                                label: '提議新增',
                                onTap: _proposeActivityType,
                              ),
                            ],
                          ),
                          if (_selectedType?.description != null) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              _selectedType!.description!,
                              style: textTheme.bodySmall,
                            ),
                          ],
                          if (_typeHasParameters(_selectedType))
                            KeyedSubtree(
                              key: _activityParamsKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // v1.42 — 運動專屬強度/實力/NTRP 等級與選填積分
                                  Builder(
                                    builder: (context) {
                                      final sportConfig =
                                          SportLevelConfig.forSystem(
                                            _selectedType?.levelSystem,
                                          );
                                      if (sportConfig == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const SizedBox(height: AppSpacing.lg),
                                          Text(
                                            sportConfig.sectionTitle,
                                            style: textTheme.titleSmall,
                                          ),
                                          if (sportConfig.helperText !=
                                              null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              sportConfig.helperText!,
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                          const SizedBox(height: AppSpacing.xs),
                                          Wrap(
                                            spacing: AppSpacing.sm,
                                            runSpacing: AppSpacing.xs,
                                            children: [
                                              ChoiceChip(
                                                label: Text(
                                                  sportConfig.wildcardLabel,
                                                ),
                                                selected:
                                                    _selectedSportLevel == null,
                                                onSelected: AppHaptics.select(
                                                  (_) {
                                                    setState(
                                                      () =>
                                                          _selectedSportLevel =
                                                              null,
                                                    );
                                                    if (!sportConfig
                                                        .supportsRating) {
                                                      _scrollToSection(
                                                        _timeSectionKey,
                                                      );
                                                    }
                                                  },
                                                ),
                                              ),
                                              for (final opt
                                                  in sportConfig.options)
                                                ChoiceChip(
                                                  label: Text(
                                                    opt.displayChipLabel,
                                                  ),
                                                  selected:
                                                      _selectedSportLevel ==
                                                      opt.value,
                                                  onSelected: AppHaptics.select(
                                                    (_) {
                                                      setState(
                                                        () =>
                                                            _selectedSportLevel =
                                                                opt.value,
                                                      );
                                                      if (!sportConfig
                                                          .supportsRating) {
                                                        _scrollToSection(
                                                          _timeSectionKey,
                                                        );
                                                      }
                                                    },
                                                  ),
                                                ),
                                            ],
                                          ),
                                          if (sportConfig.supportsRating) ...[
                                            const SizedBox(
                                              height: AppSpacing.sm,
                                            ),
                                            AppTextField(
                                              controller: _ratingController,
                                              label:
                                                  sportConfig.ratingLabel ??
                                                  '積分（選填）',
                                              hint:
                                                  sportConfig.ratingHint ??
                                                  '例如：約 1450',
                                              keyboardType:
                                                  TextInputType.number,
                                              onChanged: (_) => setState(() {}),
                                              onSubmitted: (_) =>
                                                  _scrollToSection(
                                                    _timeSectionKey,
                                                  ),
                                            ),
                                          ],
                                        ],
                                      );
                                    },
                                  ),
                                  // v1.35 — 只有讀書類型顯示，選填。
                                  if (_selectedType?.name == '讀書') ...[
                                    const SizedBox(height: AppSpacing.lg),
                                    Text(
                                      '想找同樣在準備什麼的人？（選填）',
                                      style: textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    Wrap(
                                      spacing: AppSpacing.xs,
                                      runSpacing: AppSpacing.xs,
                                      children: [
                                        for (final subject
                                            in _popularStudySubjects)
                                          ActionChip(
                                            label: Text(subject),
                                            onPressed: () {
                                              setState(
                                                () =>
                                                    _studyTargetController
                                                        .text = subject,
                                              );
                                              _scrollToSection(_timeSectionKey);
                                            },
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: AppSpacing.sm),
                                    AppTextField(
                                      controller: _studyTargetController,
                                      label: '科目/課程/考試名稱',
                                      hint: '例如：微積分(一)、雅思、多益',
                                      onChanged: (_) => setState(() {}),
                                      onSubmitted: (_) =>
                                          _scrollToSection(_timeSectionKey),
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    Text(
                                      '想找完全同一堂課的人？可以連老師一起打，例如「微積分(一) 陳大文」——但比對是完全比對，'
                                      '要對方也打一模一樣的內容才會配對成功，不確定的話單打科目名稱就好',
                                      style: textTheme.bodySmall?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    if (_studyTargetController
                                        .text
                                        .isNotEmpty) ...[
                                      const SizedBox(height: AppSpacing.xs),
                                      Builder(
                                        builder: (context) {
                                          final normalized =
                                              _normalizeStudyTargetPreview(
                                                _studyTargetController.text,
                                              );
                                          return Text(
                                            normalized == null
                                                ? '目前輸入不會被當作指定條件（等同不限）'
                                                : '將以「$normalized」進行比對',
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.onSurfaceVariant,
                                                ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                    KeyedSubtree(
                      key: _timeSectionKey,
                      child: AppSection(
                        title: '時間',
                        description: '什麼時候？',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => setState(() {
                                  _detailedMode = !_detailedMode;
                                  _nowSelected = false;
                                  _selectedBucketIndices.clear();
                                }),
                                child: Text(_detailedMode ? '改選時段' : '自訂時間'),
                              ),
                            ),
                            if (_detailedMode) ...[
                              OutlinedButton(
                                onPressed: () =>
                                    _pickCustomTime(isEarliest: true),
                                child: Text(
                                  _customEarliest == null
                                      ? '最早開始時間'
                                      : _formatTime(_customEarliest!),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              OutlinedButton(
                                onPressed: () =>
                                    _pickCustomTime(isEarliest: false),
                                child: Text(
                                  _customLatest == null
                                      ? '最晚開始時間'
                                      : _formatTime(_customLatest!),
                                ),
                              ),
                            ] else
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
                                      selected: _selectedBucketIndices.contains(
                                        i,
                                      ),
                                      onTap: () => _toggleBucket(i),
                                    ),
                                ],
                              ),
                            if (window != null) ...[
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                '已選範圍：${_timeWindowLabel(window)}',
                                style: textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    KeyedSubtree(
                      key: _campusSectionKey,
                      child: AppSection(
                        title: '校區',
                        description: '去哪個校區？',
                        child: campusAsync.when(
                          loading: () => const LoadingIndicator(),
                          error: (error, stack) => const AppErrorState(),
                          data: (campuses) {
                            if (campuses.isEmpty) {
                              return Text(
                                '這個學校目前還沒有已核准的地點，請聯絡管理員',
                                style: textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              );
                            }
                            if (_selectedCampus == null ||
                                !campuses.contains(_selectedCampus)) {
                              // v1.32 — 優先帶入 app_user.default_campus（註冊時選過，或
                              // 上次建立揪團時回寫的值），沒有才 fallback 第一個選項。
                              final defaultCampus = user.defaultCampus;
                              _selectedCampus =
                                  (defaultCampus != null &&
                                      campuses.contains(defaultCampus))
                                  ? defaultCampus
                                  : campuses.first;
                            }
                            // MVP 單校區假設（見 campusOptionsProvider 註解）：只有一個
                            // 選項時直接帶入顯示，不再讓使用者多一步選擇；反饋：地點清單
                            // 不該把測試/內部資料攤在使用者面前，這裡也不再列出任何原始
                            // 地點名稱，只顯示校區。
                            if (campuses.length == 1) {
                              return Row(
                                children: [
                                  Icon(
                                    Icons.location_on_rounded,
                                    size: 20,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      '校區：${campuses.first}',
                                      style: textTheme.titleSmall,
                                    ),
                                  ),
                                ],
                              );
                            }
                            return Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.sm,
                              children: [
                                for (final campus in campuses)
                                  _TimeChip(
                                    icon: Icons.location_on_rounded,
                                    label: campus,
                                    selected: _selectedCampus == campus,
                                    onTap: () {
                                      setState(() => _selectedCampus = campus);
                                      ref
                                          .read(selectedCampusProvider.notifier)
                                          .setCampus(campus);
                                      _scrollToSection(_headcountSectionKey);
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    KeyedSubtree(
                      key: _headcountSectionKey,
                      child: AppSection(
                        title: '人數',
                        description: '整團大約要幾個人？',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '人數是整團的總人數，含你自己',
                              style: textTheme.bodySmall?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (_selectedType == null)
                              Text('請先選活動類型', style: textTheme.bodySmall)
                            else
                              reliabilityAsync.when(
                                loading: () => const LoadingIndicator(),
                                error: (error, stack) => const AppErrorState(),
                                data: (reliability) {
                                  final options = _groupSizeOptions(
                                    _selectedType!,
                                  );
                                  final scheme = Theme.of(context).colorScheme;
                                  final hasLockedOption =
                                      reliability.isNewUser &&
                                      options.any((n) => n <= 2);
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('至少', style: textTheme.bodySmall),
                                      const SizedBox(height: AppSpacing.xs),
                                      Wrap(
                                        spacing: AppSpacing.sm,
                                        children: [
                                          for (final n in options)
                                            // UI_PLAN §2.2：New tier 使用者 ≤2 人選項直接 disable。
                                            // 反饋：disable 但沒有任何說明，使用者不知道為什麼點不動
                                            // ——用 Tooltip（長按/hover 可看）+ 下方常駐提示文字
                                            // 兩種方式解釋原因，不用等送出才看到 NEW_USER_LOW_HEADCOUNT。
                                            Tooltip(
                                              message:
                                                  (n <= 2 &&
                                                      reliability.isNewUser)
                                                  ? '新用戶尚未開放 2 人以下場次'
                                                  : '',
                                              triggerMode:
                                                  TooltipTriggerMode.tap,
                                              child: ChoiceChip(
                                                label: Text('$n 人'),
                                                selected:
                                                    _selectedMinHeadcount == n,
                                                onSelected:
                                                    (n <= 2 &&
                                                        reliability.isNewUser)
                                                    ? null
                                                    : AppHaptics.select(
                                                        (_) => setState(() {
                                                          _selectedMinHeadcount =
                                                              n;
                                                          // 最多不能小於最少——若原本選的最多比新的
                                                          // 最少還小，直接清掉讓使用者重選。
                                                          if (_selectedMaxHeadcount !=
                                                                  null &&
                                                              _selectedMaxHeadcount! <
                                                                  n) {
                                                            _selectedMaxHeadcount =
                                                                null;
                                                          }
                                                        }),
                                                      ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      if (hasLockedOption) ...[
                                        const SizedBox(height: AppSpacing.xs),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              Icons.info_outline_rounded,
                                              size: 14,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                            const SizedBox(
                                              width: AppSpacing.xs,
                                            ),
                                            Expanded(
                                              child: Text(
                                                '新用戶需要先完成一次活動、建立信譽後，才能發起 2 人以下的小型場次',
                                                style: textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const SizedBox(height: AppSpacing.md),
                                      Text('至多', style: textTheme.bodySmall),
                                      const SizedBox(height: AppSpacing.xs),
                                      if (_selectedMinHeadcount == null)
                                        Text(
                                          '請先選「至少」人數',
                                          style: textTheme.bodySmall,
                                        )
                                      else
                                        Wrap(
                                          spacing: AppSpacing.sm,
                                          children: [
                                            for (final n in options)
                                              if (n >= _selectedMinHeadcount!)
                                                ChoiceChip(
                                                  label: Text('$n 人'),
                                                  selected:
                                                      _selectedMaxHeadcount ==
                                                      n,
                                                  onSelected: AppHaptics.select(
                                                    (_) => setState(
                                                      () =>
                                                          _selectedMaxHeadcount =
                                                              n,
                                                    ),
                                                  ),
                                                ),
                                          ],
                                        ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    AppSection(
                      title: '降級配對',
                      description: '如果人數不足，可以選擇接受較少人也成立活動。',
                      child: Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _allowDowngrade,
                          onChanged: (v) => setState(() => _allowDowngrade = v),
                          title: const Text('人數不夠時，接受少一點人也算成局？'),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    AppSection(
                      title: '送出前確認',
                      description: '請確認目前選擇；送出後會開始尋找符合條件的人。',
                      child: AppSelectionSummary(
                        items: _selectionSummaryItems(window),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                  ],
                ),
              ),
              AppStickyActionArea(
                child: Builder(
                  builder: (context) {
                    final missing = _missingRequiredChoice(window);
                    final actionHint = hasActiveState
                        ? (activeRequest != null
                            ? '你已有進行中的配對，請先前往等待室或取消後再發起新配對'
                            : '你目前有進行中的活動，請先前往活動或結束後再發起新配對')
                        : (isCooldown ? '配對冷卻中，暫時無法送出' : missing);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (actionHint != null) ...[
                          Text(
                            actionHint,
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(
                              color: hasActiveState
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                        if (_error != null) ...[
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                        AppButton(
                          label: hasActiveState
                              ? (activeRequest != null ? '已在配對等待室中' : '活動進行中')
                              : (isCooldown ? '配對冷卻中，暫時無法送出' : '送出，開始找人'),
                          loading: _submitting,
                          onPressed: hasActiveState ||
                                  isCooldown ||
                                  missing != null ||
                                  _confirming ||
                                  _submitting
                              ? null
                              : _confirmAndSubmit,
                        ),
                      ],
                    );
                  },
                ),
              ),
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
  const _OptionCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

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
        // 選取類觸覺集中在這三個自訂選擇卡的定義裡，而不是散在十幾個呼叫點
        // ——活動類型格、時段桶、校區全都走這條路徑。
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: selected
                ? Border.all(color: scheme.primary, width: 2)
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 28,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
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
        // 選取類觸覺集中在這三個自訂選擇卡的定義裡，而不是散在十幾個呼叫點
        // ——活動類型格、時段桶、校區全都走這條路徑。
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: scheme.outlineVariant,
              style: BorderStyle.solid,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 28, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
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
  const _TimeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

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
        // 選取類觸覺集中在這三個自訂選擇卡的定義裡，而不是散在十幾個呼叫點
        // ——活動類型格、時段桶、校區全都走這條路徑。
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
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
