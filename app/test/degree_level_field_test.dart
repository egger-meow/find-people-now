import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/generated/supadart_header.dart' show DEGREE_LEVEL;
import 'package:find_people_now/widgets/degree_level_field.dart';

void main() {
  group('DegreeLevelField', () {
    testWidgets('renders all degree level options and updates on tap', (tester) async {
      DEGREE_LEVEL currentLevel = DEGREE_LEVEL.UNDERGRAD;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return DegreeLevelField(
                  selectedDegreeLevel: currentLevel,
                  onChanged: (val) => setState(() => currentLevel = val),
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('學制'), findsOneWidget);
      expect(find.text('大學部'), findsOneWidget);
      expect(find.text('碩士班'), findsOneWidget);
      expect(find.text('博士班'), findsOneWidget);

      // Tap '碩士班'
      await tester.tap(find.text('碩士班'));
      await tester.pumpAndSettle();

      expect(currentLevel, DEGREE_LEVEL.MASTER);

      // Tap '博士班'
      await tester.tap(find.text('博士班'));
      await tester.pumpAndSettle();

      expect(currentLevel, DEGREE_LEVEL.PHD);
    });
  });
}
