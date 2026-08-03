import '../generated/supadart_header.dart' show SKILL_LEVEL;

/// v1.34 — Skill Level 顯示文案，跟建立 Request 表單、等待室、活動成員名單
/// 共用同一份，避免各畫面各自維護一份容易漂移的對照表。
String skillLevelLabel(SKILL_LEVEL level) => switch (level) {
      SKILL_LEVEL.BEGINNER => '新手',
      SKILL_LEVEL.CASUAL => '一般',
      SKILL_LEVEL.ADVANCED => '進階',
      SKILL_LEVEL.COMPETITIVE => '競技',
    };
