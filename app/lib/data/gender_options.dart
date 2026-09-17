/// 性別標準選項與清洗邏輯
///
/// 避免自由填寫產生「男、男生、male」或「女、女生、female」等髒資料，
/// 統一收斂為三大受控值（男 / 女 / 其他），供後續活動限同性等篩選邏輯精準比對。
abstract final class GenderOptions {
  static const male = '男';
  static const female = '女';
  static const other = '其他';

  static const List<String> all = [male, female, other];

  /// 將歷史資料或外部字串正規化為受控值
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed == '男' ||
        trimmed == '男生' ||
        trimmed == '男性' ||
        trimmed.toLowerCase() == 'male' ||
        trimmed.toLowerCase() == 'm') {
      return male;
    }
    if (trimmed == '女' ||
        trimmed == '女生' ||
        trimmed == '女性' ||
        trimmed.toLowerCase() == 'female' ||
        trimmed.toLowerCase() == 'f') {
      return female;
    }
    if (trimmed == '其他' ||
        trimmed == '多元' ||
        trimmed.toLowerCase() == 'other') {
      return other;
    }
    return null;
  }
}
