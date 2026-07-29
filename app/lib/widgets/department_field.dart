import 'package:flutter/material.dart';

import '../data/department_options.dart';
import '../generated/supadart_header.dart' show SCHOOL;

/// 反饋：科系欄位要能用下拉選單選，而不是純打字——`DropdownMenu` 用
/// `controller` 綁同一個 [TextEditingController]，`enableFilter: true` 讓
/// 使用者邊打邊篩選清單，但輸入框本身仍是一般文字欄位，打的內容不在清單裡
/// 也照樣收得到（[departmentsBySchool] 的清單不保證跟得上系所異動，不該
/// 因為找不到就卡住使用者填不了科系）。
class DepartmentField extends StatelessWidget {
  const DepartmentField({super.key, required this.controller, required this.school});

  final TextEditingController controller;
  final SCHOOL? school;

  @override
  Widget build(BuildContext context) {
    final options = departmentsBySchool[school] ?? const <String>[];
    return DropdownMenu<String>(
      controller: controller,
      width: MediaQuery.sizeOf(context).width - 48,
      menuHeight: 360,
      enableFilter: true,
      requestFocusOnTap: true,
      label: const Text('科系（選填，可輸入搜尋或直接手動輸入）'),
      dropdownMenuEntries: [
        for (final department in options) DropdownMenuEntry(value: department, label: department),
      ],
    );
  }
}
