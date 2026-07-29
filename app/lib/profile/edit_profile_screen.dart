import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL;
import '../match/match_providers.dart' show myAppUserProvider;
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import '../widgets/department_field.dart';
import '../widgets/loading_indicator.dart';
import 'avatar_upload.dart';

/// UI_PLAN.md §8.1「我的」的完整編輯頁——跟 auth/complete_profile_screen.dart
/// 的最小註冊 gate 不是同一個畫面，但底層共用同一個 `complete_profile` RPC：
/// 該 RPC 本身是 `on conflict (id) do update` 的 upsert（見
/// RPC_COVERAGE.md v1.14 條目），所以拿來做「編輯既有資料」也是正確用法，
/// 而不是繞道走欄位授權——`degree_level`/`department` 根本不在
/// `20260724125200_restrict_app_user_notification_column_grants.sql` 收斂後
/// 的 column-grant 允許清單內，直接 PATCH `app_user` 對這兩欄會被 42501 擋下，
/// 唯一合法寫入路徑就是這支 RPC。
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _displayNameController = TextEditingController();
  final _departmentController = TextEditingController();
  final _genderController = TextEditingController();
  final _bioController = TextEditingController();
  final _contactIgController = TextEditingController();
  final _contactLineController = TextEditingController();
  final _contactDiscordController = TextEditingController();
  DEGREE_LEVEL _degreeLevel = DEGREE_LEVEL.UNDERGRAD;
  String _avatarUrl = '';
  bool _initialized = false;
  bool _loading = false;
  bool _uploadingAvatar = false;
  String? _error;

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
    final seed = '${_displayNameController.text.trim()}-${DateTime.now().millisecondsSinceEpoch}';
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
      ref.invalidate(myAppUserProvider);
      if (mounted) context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '儲存失敗：${e.code.name}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(myAppUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('編輯個人資料')),
      body: SafeArea(
        child: userAsync.when(
          loading: () => const LoadingIndicator(),
          error: (error, stack) => Center(child: Text('載入失敗：$error')),
          data: (user) {
            if (user == null) return const LoadingIndicator();
            if (!_initialized) {
              _initialized = true;
              _displayNameController.text = user.displayName;
              _departmentController.text = user.department ?? '';
              _genderController.text = user.gender ?? '';
              _bioController.text = user.bio ?? '';
              _contactIgController.text = user.contactIg ?? '';
              _contactLineController.text = user.contactLine ?? '';
              _contactDiscordController.text = user.contactDiscord ?? '';
              _degreeLevel = user.degreeLevel;
              _avatarUrl = user.avatarUrl;
            }

            return ListView(
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
                          if (_uploadingAvatar)
                            const CircularProgressIndicator(strokeWidth: 2.4),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: _uploadingAvatar ? null : _uploadAvatar,
                            child: const Text('上傳照片'),
                          ),
                          TextButton(
                            onPressed: _uploadingAvatar ? null : _rerollAvatar,
                            child: const Text('隨機頭像'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
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
                    if (value != null) setState(() => _degreeLevel = value);
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                DepartmentField(controller: _departmentController, school: user.school),
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
                AppButton(label: '儲存', loading: _loading, onPressed: _submit),
              ],
            );
          },
        ),
      ),
    );
  }
}
