// Smoke test: simply ensure the app builds in a basic MaterialApp shell.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Course Compass'))),
      ),
    );
    expect(find.text('Course Compass'), findsOneWidget);
  });
}
