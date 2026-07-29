import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import 'auth_providers.dart';

/// 反饋：驗證碼信件可能延遲或漏收，卡在「重新輸入信箱」這條路太重（要整個
/// 重填一次）——加一個原地重新傳送的選項。跟伺服器端 `max_frequency = "1s"`
/// （config.toml）分開設一個更保守的前端冷卻秒數，純粹是防止使用者手滑連點
/// 造成信箱被灌爆，不是在補伺服器端沒做的節流。
const _resendCooldown = Duration(seconds: 30);

/// docs/SPEC.md §2：學校專屬網域信箱（`@nycu.edu.tw` / `@nthu.edu.tw`）+ OTP。
/// 最小可用登入畫面——這輪的必要 gate，不是後續輪次要打磨的畫面；沒有做
/// 「記住我」、社群登入等額外功能。
///
/// 網域格式檢查只是即時給使用者的提示，真正的權威驗證在後端
/// `complete_profile`（20260724120200_rpc_profile_and_auth.sql:69-75）——這裡
/// 允許任何格式正確的 email 送出 OTP，讓伺服器端的 `INVALID_EMAIL_DOMAIN`
/// 保留為最終防線，不重複兩套判斷邏輯。
final _schoolDomainPattern = RegExp(r'^[^@\s]+@(nycu|nthu)\.edu\.tw$', caseSensitive: false);

class OtpLoginScreen extends ConsumerStatefulWidget {
  const OtpLoginScreen({super.key});

  @override
  ConsumerState<OtpLoginScreen> createState() => _OtpLoginScreenState();
}

class _OtpLoginScreenState extends ConsumerState<OtpLoginScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();

  bool _otpSent = false;
  bool _loading = false;
  bool _resending = false;
  String? _error;
  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = _resendCooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
      } else {
        setState(() => _cooldownSeconds -= 1);
      }
    });
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (!_schoolDomainPattern.hasMatch(email)) {
      setState(() => _error = '請輸入 @nycu.edu.tw 或 @nthu.edu.tw 學校信箱');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(supabaseClientProvider).auth.signInWithOtp(email: email);
      if (!mounted) return;
      setState(() {
        _otpSent = true;
        _loading = false;
      });
      _startCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '驗證信寄送失敗，請稍後再試';
        _loading = false;
      });
    }
  }

  Future<void> _resendOtp() async {
    final email = _emailController.text.trim();
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      await ref.read(supabaseClientProvider).auth.signInWithOtp(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已重新寄送驗證碼')),
      );
      _startCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '重新寄送失敗，請稍後再試');
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '請輸入驗證碼');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(supabaseClientProvider).auth.verifyOTP(
            email: email,
            token: code,
            type: OtpType.email,
          );
      // Successful verifyOTP updates the session; authStateProvider (watched
      // by go_router's redirect) picks this up on its own — no manual nav.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '驗證碼錯誤或已過期';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.groups_2_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: AppSpacing.md),
              Text(
                '校園裡有人正在做事，\n而你隨時可以加入。',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppTextField(
                controller: _emailController,
                label: '學校信箱',
                hint: 'example@nycu.edu.tw',
                keyboardType: TextInputType.emailAddress,
                enabled: !_otpSent,
                onSubmitted: (_) => _otpSent ? null : _sendOtp(),
              ),
              if (_otpSent) ...[
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _codeController,
                  label: '驗證碼',
                  hint: '6 位數字',
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  onSubmitted: (_) => _verifyOtp(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: _otpSent ? '驗證並登入' : '傳送驗證碼',
                loading: _loading,
                onPressed: _otpSent ? _verifyOtp : _sendOtp,
              ),
              if (_otpSent) ...[
                TextButton(
                  onPressed: (_loading || _resending || _cooldownSeconds > 0) ? null : _resendOtp,
                  child: Text(_cooldownSeconds > 0 ? '重新傳送驗證碼（$_cooldownSeconds 秒後可用）' : '重新傳送驗證碼'),
                ),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                            _otpSent = false;
                            _codeController.clear();
                            _error = null;
                            _cooldownTimer?.cancel();
                            _cooldownSeconds = 0;
                          }),
                  child: const Text('重新輸入信箱'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
