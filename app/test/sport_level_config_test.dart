import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/data/sport_level_config.dart';
import 'package:find_people_now/generated/supadart_header.dart' show LEVEL_SYSTEM;

void main() {
  group('SportLevelConfig unit tests', () {
    test('Basketball intensity config and formatting', () {
      final config = SportLevelConfig.forSystem(LEVEL_SYSTEM.BASKETBALL_INTENSITY);
      expect(config, isNotNull);
      expect(config!.sectionTitle, '籃球強度');
      expect(config.fieldLabel, '強度');
      expect(config.wildcardLabel, '不限');
      expect(config.supportsRating, isFalse);

      expect(config.formatLevel(null), '不限');
      expect(config.formatLevel('HIGH'), '高強度');
      expect(config.formatFieldSummary('HIGH'), '強度：高強度');
      expect(config.formatWithActivityName('籃球', 'COMPETITIVE'), '籃球｜強度：競技');
    });

    test('Badminton level band config and formatting', () {
      final config = SportLevelConfig.forSystem(LEVEL_SYSTEM.BADMINTON_LEVEL);
      expect(config, isNotNull);
      expect(config!.sectionTitle, '羽球實力');
      expect(config.fieldLabel, '實力');
      expect(config.wildcardLabel, '不限 / 不確定');
      expect(config.supportsRating, isFalse);

      expect(config.formatLevel('LEVEL_6_7'), '6–7 級');
      expect(config.formatFieldSummary('LEVEL_6_7'), '實力：6–7 級');
      expect(config.formatWithActivityName('羽球', 'LEVEL_8_10'), '羽球｜實力：8–10 級');
    });

    test('Tennis NTRP config and formatting', () {
      final config = SportLevelConfig.forSystem(LEVEL_SYSTEM.TENNIS_NTRP);
      expect(config, isNotNull);
      expect(config!.sectionTitle, '網球 NTRP');
      expect(config.fieldLabel, 'NTRP');
      expect(config.wildcardLabel, '不限 / 不知道');
      expect(config.helperText, '不知道 NTRP 沒關係，可選不限');
      expect(config.supportsRating, isFalse);

      expect(config.formatLevel('NTRP_3_5'), '3.5');
      expect(config.formatFieldSummary('NTRP_3_5'), 'NTRP：3.5');
      expect(config.formatWithActivityName('網球', 'NTRP_3_5'), '網球｜NTRP：3.5');
    });

    test('Table Tennis skill and optional rating config and formatting', () {
      final config = SportLevelConfig.forSystem(LEVEL_SYSTEM.TABLE_TENNIS_SKILL);
      expect(config, isNotNull);
      expect(config!.sectionTitle, '桌球實力');
      expect(config.fieldLabel, '實力');
      expect(config.wildcardLabel, '不限 / 不確定');
      expect(config.supportsRating, isTrue);

      expect(config.formatLevel('REGULAR_PLAYER'), '固定打球');
      expect(config.formatFieldSummary('REGULAR_PLAYER'), '實力：固定打球');
      expect(
        config.formatFieldSummary('REGULAR_PLAYER', rating: 1450),
        '實力：固定打球（積分約 1450）',
      );
      expect(
        config.formatWithActivityName('桌球', 'BASIC_SKILLS', rating: 1200),
        '桌球｜實力：有基本功（積分約 1200）',
      );
    });

    test('Dance genre config and formatting', () {
      final config = SportLevelConfig.forSystem(LEVEL_SYSTEM.DANCE_GENRE);
      expect(config, isNotNull);
      expect(config!.sectionTitle, '練舞曲風');
      expect(config.fieldLabel, '曲風');
      expect(config.wildcardLabel, '不限 / 都可以');
      expect(config.supportsRating, isFalse);

      expect(config.formatLevel(null), '不限 / 都可以');
      expect(config.formatLevel('HIPHOP'), 'Hip-Hop');
      expect(config.formatLevel('JAZZ'), 'Jazz');
      expect(config.formatLevel('GIRLSTYLE'), 'Girl Style');
      expect(config.formatLevel('POPPING'), 'Popping');
      expect(config.formatLevel('LOCKING'), 'Locking');
      expect(config.formatLevel('OTHER'), '其他曲風');
      expect(config.formatFieldSummary('HIPHOP'), '曲風：Hip-Hop');
      expect(config.formatWithActivityName('練舞', 'HIPHOP'), '練舞｜曲風：Hip-Hop');
    });

    test('Non-sport returns null config and fallback formatting', () {
      expect(SportLevelConfig.forSystem(LEVEL_SYSTEM.NONE), isNull);
      expect(SportLevelConfig.forSystem(null), isNull);
      expect(SportLevelConfig.format(LEVEL_SYSTEM.NONE, 'ANY'), '不限');
      expect(
        SportLevelConfig.format(LEVEL_SYSTEM.NONE, null, fallback: '無限制'),
        '無限制',
      );
    });
  });
}
