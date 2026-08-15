import '../generated/supadart_header.dart' show LEVEL_SYSTEM;

/// 運動等級/強度單一選項定義
class SportLevelOption {
  const SportLevelOption({
    required this.value,
    required this.label,
    this.chipLabel,
    this.secondaryDescription,
  });

  /// 儲存於 match_request.sport_level 的字串值
  final String value;

  /// 完整顯示文案（例如：1–5 級、2.0 以下、校隊 / 積分賽程度）
  final String label;

  /// Option chip 上的簡潔文字（若為 null 則使用 [label]）
  final String? chipLabel;

  /// 次要補充說明（例如：初階、中階、高階、競技）
  final String? secondaryDescription;

  String get displayChipLabel => chipLabel ?? label;
}

/// 集中定義各運動等級/強度系統的核心配置與格式化
///
/// 避免在各畫面（建立表單、確認視窗、等待室、活動詳情、個人卡片）分散撰寫
/// `if (activity.name == '羽球')` 或維護多份容易漂移的文案對照表。
class SportLevelConfig {
  const SportLevelConfig({
    required this.system,
    required this.sectionTitle,
    required this.fieldLabel,
    required this.wildcardLabel,
    required this.options,
    this.helperText,
    this.supportsRating = false,
    this.ratingLabel,
    this.ratingHint,
  });

  final LEVEL_SYSTEM system;

  /// 在建立表單上的區塊標題（例如：籃球強度、羽球實力、網球 NTRP、桌球實力）
  final String sectionTitle;

  /// 屬性標籤（例如：強度、實力、NTRP）
  final String fieldLabel;

  /// 不限 / 未指定時的選項文案
  final String wildcardLabel;

  /// 輔助說明文字（例如：網球「不知道 NTRP 沒關係，可選不限」）
  final String? helperText;

  /// 可選等級項目清單（不含 wildcard，wildcard 統一為 null）
  final List<SportLevelOption> options;

  /// 是否支援選填積分（例如：桌球）
  final bool supportsRating;

  /// 積分輸入標籤
  final String? ratingLabel;

  /// 積分輸入提示
  final String? ratingHint;

  /// 依 value 查詢對應選項
  SportLevelOption? findOption(String? value) {
    if (value == null) return null;
    for (final opt in options) {
      if (opt.value == value) return opt;
    }
    return null;
  }

  /// 取得選項顯示名稱（若為 null 則回傳 [wildcardLabel] 或預設「不限」）
  String formatLevel(String? value, {bool short = false}) {
    if (value == null) return wildcardLabel;
    final opt = findOption(value);
    if (opt == null) return value;
    return short ? opt.displayChipLabel : opt.label;
  }

  /// 格式化為完整屬性字串（例如：「強度：高強度」、「實力：6–7 級」、「NTRP：3.5」）
  String formatFieldSummary(String? value, {int? rating}) {
    final levelStr = formatLevel(value);
    if (supportsRating && rating != null && rating > 0) {
      return '$fieldLabel：$levelStr（積分約 $rating）';
    }
    return '$fieldLabel：$levelStr';
  }

  /// 取得帶活動名稱前綴的完整描述（例如：「籃球｜強度：高強度」）
  String formatWithActivityName(String activityName, String? value, {int? rating}) {
    final summary = formatFieldSummary(value, rating: rating);
    return '$activityName｜$summary';
  }

  // ---------------------------------------------------------------------------
  // 官方預設配置實例
  // ---------------------------------------------------------------------------

  static const basketball = SportLevelConfig(
    system: LEVEL_SYSTEM.BASKETBALL_INTENSITY,
    sectionTitle: '籃球強度',
    fieldLabel: '強度',
    wildcardLabel: '不限',
    options: [
      SportLevelOption(value: 'EASY', label: '輕鬆'),
      SportLevelOption(value: 'REGULAR', label: '一般'),
      SportLevelOption(value: 'HIGH', label: '高強度'),
      SportLevelOption(value: 'COMPETITIVE', label: '競技'),
    ],
  );

  static const badminton = SportLevelConfig(
    system: LEVEL_SYSTEM.BADMINTON_LEVEL,
    sectionTitle: '羽球實力',
    fieldLabel: '實力',
    wildcardLabel: '不限 / 不確定',
    options: [
      SportLevelOption(
        value: 'LEVEL_1_5',
        label: '1–5 級',
        chipLabel: '1–5 級',
        secondaryDescription: '初階',
      ),
      SportLevelOption(
        value: 'LEVEL_6_7',
        label: '6–7 級',
        chipLabel: '6–7 級',
        secondaryDescription: '中階',
      ),
      SportLevelOption(
        value: 'LEVEL_8_10',
        label: '8–10 級',
        chipLabel: '8–10 級',
        secondaryDescription: '高階',
      ),
      SportLevelOption(
        value: 'LEVEL_11_PLUS',
        label: '11 級以上',
        chipLabel: '11+ 級',
        secondaryDescription: '競技',
      ),
    ],
  );

  static const tennis = SportLevelConfig(
    system: LEVEL_SYSTEM.TENNIS_NTRP,
    sectionTitle: '網球 NTRP',
    fieldLabel: 'NTRP',
    wildcardLabel: '不限 / 不知道',
    helperText: '不知道 NTRP 沒關係，可選不限',
    options: [
      SportLevelOption(value: 'NTRP_2_0', label: '2.0 以下', chipLabel: '≤2.0'),
      SportLevelOption(value: 'NTRP_2_5', label: '2.5'),
      SportLevelOption(value: 'NTRP_3_0', label: '3.0'),
      SportLevelOption(value: 'NTRP_3_5', label: '3.5'),
      SportLevelOption(value: 'NTRP_4_0', label: '4.0'),
      SportLevelOption(value: 'NTRP_4_5', label: '4.5'),
      SportLevelOption(value: 'NTRP_5_0_PLUS', label: '5.0+', chipLabel: '5.0+'),
    ],
  );

  static const tableTennis = SportLevelConfig(
    system: LEVEL_SYSTEM.TABLE_TENNIS_SKILL,
    sectionTitle: '桌球實力',
    fieldLabel: '實力',
    wildcardLabel: '不限 / 不確定',
    supportsRating: true,
    ratingLabel: '積分（選填）',
    ratingHint: '例如：約 1450',
    options: [
      SportLevelOption(value: 'CASUAL_BEGINNER', label: '休閒新手'),
      SportLevelOption(value: 'BASIC_SKILLS', label: '有基本功'),
      SportLevelOption(value: 'REGULAR_PLAYER', label: '固定打球'),
      SportLevelOption(
        value: 'VARSITY_TOURNAMENT',
        label: '校隊 / 積分賽程度',
        chipLabel: '校隊 / 積分賽',
      ),
    ],
  );

  /// 依 [LEVEL_SYSTEM] 取得對應的配置（若為 NONE 或未支援則回傳 null）
  static SportLevelConfig? forSystem(LEVEL_SYSTEM? system) {
    if (system == null || system == LEVEL_SYSTEM.NONE) return null;
    return switch (system) {
      LEVEL_SYSTEM.BASKETBALL_INTENSITY => basketball,
      LEVEL_SYSTEM.BADMINTON_LEVEL => badminton,
      LEVEL_SYSTEM.TENNIS_NTRP => tennis,
      LEVEL_SYSTEM.TABLE_TENNIS_SKILL => tableTennis,
      LEVEL_SYSTEM.NONE => null,
    };
  }

  /// 兼容舊呼叫：依 [LEVEL_SYSTEM] 與值格式化顯示文字
  static String format(LEVEL_SYSTEM? system, String? value, {int? rating, String? fallback}) {
    final config = forSystem(system);
    if (config == null || value == null) return fallback ?? '不限';
    return config.formatFieldSummary(value, rating: rating);
  }
}
