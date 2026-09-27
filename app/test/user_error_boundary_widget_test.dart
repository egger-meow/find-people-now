import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/errors/user_error_message.dart';
import 'package:find_people_now/main.dart' show buildUserSafeErrorWidget;

void main() {
  testWidgets('framework fallback 只呈現友善訊息', (tester) async {
    const technicalMessage = 'RenderFlex secret stack database.internal';
    final fallback = buildUserSafeErrorWidget(
      FlutterErrorDetails(exception: StateError(technicalMessage)),
    );

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: fallback)));

    expect(find.text(userSafeUnexpectedErrorMessage), findsOneWidget);
    expect(find.text('出了點問題'), findsOneWidget);
    final mascot = tester.widget<Image>(find.byType(Image));
    expect((mascot.image as AssetImage).assetName, 'assets/mascot/error_06.png');
    expect(find.textContaining(technicalMessage), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });
}
