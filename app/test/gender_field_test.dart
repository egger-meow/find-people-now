import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:find_people_now/data/gender_options.dart';
import 'package:find_people_now/widgets/gender_field.dart';

void main() {
  group('GenderOptions.normalize', () {
    test('normalizes male aliases', () {
      expect(GenderOptions.normalize('男'), '男');
      expect(GenderOptions.normalize('男生'), '男');
      expect(GenderOptions.normalize('男性'), '男');
      expect(GenderOptions.normalize('male'), '男');
      expect(GenderOptions.normalize('MALE'), '男');
      expect(GenderOptions.normalize('m'), '男');
      expect(GenderOptions.normalize('  男  '), '男');
    });

    test('normalizes female aliases', () {
      expect(GenderOptions.normalize('女'), '女');
      expect(GenderOptions.normalize('女生'), '女');
      expect(GenderOptions.normalize('女性'), '女');
      expect(GenderOptions.normalize('female'), '女');
      expect(GenderOptions.normalize('FEMALE'), '女');
      expect(GenderOptions.normalize('f'), '女');
      expect(GenderOptions.normalize('  女  '), '女');
    });

    test('normalizes other aliases', () {
      expect(GenderOptions.normalize('其他'), '其他');
      expect(GenderOptions.normalize('多元'), '其他');
      expect(GenderOptions.normalize('other'), '其他');
    });

    test('returns null for unrecognized or empty inputs', () {
      expect(GenderOptions.normalize(null), isNull);
      expect(GenderOptions.normalize(''), isNull);
      expect(GenderOptions.normalize('   '), isNull);
      expect(GenderOptions.normalize('武裝直升機'), isNull);
      expect(GenderOptions.normalize('unknown'), isNull);
    });
  });

  group('GenderField widget', () {
    testWidgets('renders all options and selects on tap', (tester) async {
      String? currentGender;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return GenderField(
                  selectedGender: currentGender,
                  onChanged: (val) => setState(() => currentGender = val),
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('男'), findsOneWidget);
      expect(find.text('女'), findsOneWidget);
      expect(find.text('其他'), findsOneWidget);
      expect(find.text('性別'), findsOneWidget);

      // Tap '男'
      await tester.tap(find.text('男'));
      await tester.pumpAndSettle();
      expect(currentGender, '男');

      // Tap '女'
      await tester.tap(find.text('女'));
      await tester.pumpAndSettle();
      expect(currentGender, '女');

      // Tap '女' again to unselect
      await tester.tap(find.text('女'));
      await tester.pumpAndSettle();
      expect(currentGender, isNull);
    });

    testWidgets('pre-selects normalized value from legacy data', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GenderField(
              selectedGender: '男生', // dirty legacy value
              onChanged: (_) {},
            ),
          ),
        ),
      );

      // Should not throw assertion, segment for '男' should be selected
      final segmentedButton = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmentedButton.selected, {'男'});
    });
  });
}
