import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../generated/supadart_header.dart' show DEGREE_LEVEL;
import '../match/match_providers.dart';
import '../rpc/api_exception.dart';
import '../rpc/auth_profile_rpc.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import 'auth_providers.dart';

/// 最小完善個人資料 gate（非 UI_PLAN §8.1「我的」那個完整編輯頁）。
///
/// `create_request` 硬性要求呼叫者已有 `app_user` 列，否則丟
/// `PROFILE_INCOMPLETE`（20260724124000_create_request_earliest_latest.sql:58-61）
/// ——OTP 登入完成後、能進配對頁前，必須先跑過一次 `complete_profile`。這裡只
/// 收 `complete_profile` 的硬性必填欄位（顯示名稱、大頭貼網址、學制、至少一項
/// 聯絡方式），不做完整的自我介紹/科系/性別等可選欄位，那些留給後續輪次的
/// 「我的」頁面。
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _displayNameController = TextEditingController();
  final _contactLineController = TextEditingController();
  DEGREE_LEVEL _degreeLevel = DEGREE_LEVEL.UNDERGRAD;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _displayNameController.dispose();
    _contactLineController.dispose();
    super.dispose();
  }

  String get _placeholderAvatarUrl {
    final seed = Uri.encodeComponent(
      _displayNameController.text.trim().isEmpty ? 'fpn-user' : _displayNameController.text.trim(),
    );
    return 'https://api.dicebear.com/9.x/thumbs/png?seed=$seed';
  }

  Future<void> _submit() async {
    final displayName = _displayNameController.text.trim();
    final contactLine = _contactLineController.text.trim();
    if (displayName.isEmpty) {
      setState(() => _error = '請輸入顯示名稱');
      return;
    }
    if (contactLine.isEmpty) {
      setState(() => _error = '請至少填寫一項聯絡方式（LINE ID）');
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
        avatarUrl: _placeholderAvatarUrl,
        degreeLevel: _degreeLevel,
        contactLine: contactLine,
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
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _showSeniorityReminderDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('在校生身份提醒'),
        content: const Text('提醒你，若已畢業，請注意在校生身份是本平台社群互信的基礎。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我知道了，繼續'),
          ),
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
            AppTextField(controller: _contactLineController, label: 'LINE ID'),
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
