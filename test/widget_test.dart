import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:redslide/app.dart';

Widget createTestApp() {
  return const ProviderScope(child: RedSlideApp());
}

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(createTestApp());
    expect(find.byType(RedSlideApp), findsOneWidget);
  });
}
