import 'package:flutter/material.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.keyboardType,
    this.autofocus = false,
    this.enabled = true,
    this.errorText,
    this.onSubmitted,
    this.onChanged,
    this.maxLines = 1,
    this.maxLength,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final TextInputType? keyboardType;
  final bool autofocus;
  final bool enabled;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int maxLines;

  /// 帶上限的欄位（如見面提示 30 字，見後端 CHECK 限制）會顯示即時字數計數
  /// ——原本欄位沒有任何上限提示，使用者只有送出後收到原始錯誤碼才知道超過
  /// 限制，這裡改成打字當下就看得到「還剩幾個字」。
  final int? maxLength;
  final IconData? prefixIcon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      autofocus: autofocus,
      enabled: enabled,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      maxLines: maxLines,
      maxLength: maxLength,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
      ),
    );
  }
}
