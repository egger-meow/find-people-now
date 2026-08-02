import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/department_options.dart';
import '../data/school_labels.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL;
import '../match/match_providers.dart';
import '../profile/avatar_upload.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_text_field.dart';
import '../widgets/department_field.dart';
import 'auth_providers.dart';

/// 完善個人資料 gate——OTP 登入完成後、能進配對頁前的必經畫面
/// （`create_request` 硬性要求呼叫者已有 `app_user` 列，見
/// `20260724124000_create_request_earliest_latest.sql:58-61`）。
///
/// 反饋回報過原本這裡只收顯示名稱/學制/單一 LINE ID，其餘欄位（科系、性別、
/// 自我介紹、IG/Discord）全部延後到「我的」編輯頁——使用者測試時覺得「一開始
/// 就該問的東西怎麼後面才問」，於是這輪重新設計：可選欄位一次收齊，聯絡方式
/// 開放 IG/LINE/Discord 三選一以上（跟 edit_profile_screen.dart 對齊），大頭貼
/// 也能直接上傳，不再只能重骰。刻意不加「隱私設定確認」這類額外步驟
/// （使用者明確要求不要），流程維持單頁表單，不做分步 wizard。
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _displayNameController = TextEditingController();
  final _departmentController = TextEditingController();
  final _genderController = TextEditingController();
  final _bioController = TextEditingController();
  final _contactIgController = TextEditingController();
  final _contactLineController = TextEditingController();
  final _contactDiscordController = TextEditingController();
  DEGREE_LEVEL _degreeLevel = DEGREE_LEVEL.UNDERGRAD;
  String _avatarUrl = '';
  bool _loading = false;
  bool _uploadingAvatar = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rerollAvatar();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _departmentController.dispose();
    _genderController.dispose();
    _bioController.dispose();
    _contactIgController.dispose();
    _contactLineController.dispose();
    _contactDiscordController.dispose();
    super.dispose();
  }

  void _rerollAvatar() {
    final seed =
        '${_displayNameController.text.trim().isEmpty ? 'fpn-user' : _displayNameController.text.trim()}-${DateTime.now().millisecondsSinceEpoch}';
    setState(() => _avatarUrl = 'https://api.dicebear.com/9.x/thumbs/png?seed=${Uri.encodeComponent(seed)}');
  }

  Future<void> _uploadAvatar() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final url = await pickAndUploadAvatar(ref.read(supabaseClientProvider), userId);
      if (url != null && mounted) setState(() => _avatarUrl = url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '上傳頭像失敗，請稍後再試');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _submit() async {
    final displayName = _displayNameController.text.trim();
    final contactIg = _contactIgController.text.trim();
    final contactLine = _contactLineController.text.trim();
    final contactDiscord = _contactDiscordController.text.trim();

    if (displayName.isEmpty) {
      setState(() => _error = '請輸入顯示名稱');
      return;
    }
    if (contactIg.isEmpty && contactLine.isEmpty && contactDiscord.isEmpty) {
      setState(() => _error = '請至少填寫一項聯絡方式');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final client = ref.read(supabaseClientProvider);
    try {
      // SPEC.md §2 point 5 / API.md §1 — NYCU 在校生年限軟性提醒：一次性、不阻擋。
      final needsReminder = await checkEnrollmentReminder(client, degreeLevel: _degreeLevel);
      if (needsReminder && mounted) {
        final proceed = await _showSeniorityReminderDialog();
        if (proceed != true) {
          setState(() => _loading = false);
          return;
        }
      }

      await completeProfile(
        client,
        displayName: displayName,
        avatarUrl: _avatarUrl,
        degreeLevel: _degreeLevel,
        department: _departmentController.text.trim().isEmpty ? null : _departmentController.text.trim(),
        gender: _genderController.text.trim().isEmpty ? null : _genderController.text.trim(),
        bio: _bioController.text.trim().isEmpty ? null : _bioController.text.trim(),
        contactIg: contactIg.isEmpty ? null : contactIg,
        contactLine: contactLine.isEmpty ? null : contactLine,
        contactDiscord: contactDiscord.isEmpty ? null : contactDiscord,
      );
      // authStateProvider (the router's refreshListenable) doesn't fire here
      // — same session, only the DB row changed — so invalidate
      // hasProfileProvider and navigate explicitly instead of hoping the
      // redirect re-runs on its own.
      ref.invalidate(hasProfileProvider);
      if (mounted) context.go('/match');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '送出失敗：${e.code.name}');
    } catch (e) {
      // callRpc 只把 PostgrestException 轉成 ApiException（見
      // lib/rpc/rpc_client.dart）——網路逾時/斷線等其他例外原本不會被上面那個
      // catch 接住，會一路往上丟到框架的 onError，使用者只看到按鈕的
      // loading spinner 閃一下就恢復、畫面上完全沒有任何回饋（「按了完成註冊
      // 沒反應」）。這裡補一個兜底 catch，至少確保任何失敗都有訊息可看。
      if (!mounted) return;
      setState(() => _error = '送出失敗，請檢查網路連線後再試一次');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _showSeniorityReminderDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AppAdaptiveDialog(
        title: '在校生身份提醒',
        content: const Text('提醒你，若已畢業，請注意在校生身份是本平台社群互信的基礎。'),
        actions: [
          AppDialogAction(label: '我知道了，繼續', isDefault: true, onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('完善個人資料')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Center(
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 40,
                        backgroundImage: _avatarUrl.isEmpty ? null : NetworkImage(_avatarUrl),
                        child: _avatarUrl.isEmpty ? const Icon(Icons.person_rounded, size: 40) : null,
                      ),
                      if (_uploadingAvatar) const CircularProgressIndicator(strokeWidth: 2.4),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(onPressed: _uploadingAvatar ? null : _uploadAvatar, child: const Text('上傳照片')),
                      TextButton(onPressed: _uploadingAvatar ? null : _rerollAvatar, child: const Text('隨機頭像')),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('基本資料', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: _displayNameController, label: '顯示名稱'),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<DEGREE_LEVEL>(
              initialValue: _degreeLevel,
              decoration: const InputDecoration(labelText: '學制'),
              items: const [
                DropdownMenuItem(value: DEGREE_LEVEL.UNDERGRAD, child: Text('大學部')),
                DropdownMenuItem(value: DEGREE_LEVEL.MASTER, child: Text('碩士班')),
                DropdownMenuItem(value: DEGREE_LEVEL.PHD, child: Text('博士班')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _degreeLevel = value;
                  final school = schoolFromEmail(ref.read(supabaseClientProvider).auth.currentUser?.email);
                  if (!departmentOptionsFor(school, value).contains(_departmentController.text)) {
                    _departmentController.clear();
                  }
                });
              },
            ),
            const SizedBox(height: AppSpacing.md),
            DepartmentField(
              controller: _departmentController,
              school: schoolFromEmail(ref.watch(supabaseClientProvider).auth.currentUser?.email),
              degreeLevel: _degreeLevel,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _genderController, label: '性別（選填，僅供展示，不影響配對）'),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _bioController, label: '自我介紹（選填）'),
            const SizedBox(height: AppSpacing.lg),
            Text('聯絡方式（至少填一項）', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: _contactIgController, label: 'Instagram'),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _contactLineController, label: 'LINE'),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _contactDiscordController, label: 'Discord'),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: AppSpacing.lg),
            AppButton(label: '完成註冊', loading: _loading, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
