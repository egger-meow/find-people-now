import 'package:flutter/material.dart';

import '../data/department_options.dart';
import '../generated/supadart_header.dart' show DEGREE_LEVEL, SCHOOL;

/// 反饋：科系欄位要能用下拉選單選，而不是純打字——`DropdownMenu` 用
/// `controller` 綁同一個 [TextEditingController]，`enableFilter: true` 讓
/// 使用者邊打邊篩選清單，但輸入框本身仍是一般文字欄位，打的內容不在清單裡
/// 也照樣收得到（[departmentsBySchool] 的清單不保證跟得上系所異動，不該
/// 因為找不到就卡住使用者填不了科系）。
///
/// 反饋：清單依 [degreeLevel] 分流（先選學士/碩士/博士，再篩科系）——見
/// `departmentOptionsFor`。呼叫端負責在學制切換、目前選的科系不在新清單
/// 內時清空 [controller]，這裡本身不做自動清空。
class DepartmentField extends StatelessWidget {
  const DepartmentField({super.key, required this.controller, required this.school, required this.degreeLevel});

  final TextEditingController controller;
  final SCHOOL? school;
  final DEGREE_LEVEL degreeLevel;

  @override
  Widget build(BuildContext context) {
    final options = departmentOptionsFor(school, degreeLevel);
    return DropdownMenu<String>(
      key: ValueKey(degreeLevel),
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
