import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const YinweiApp());
    expect(find.textContaining('音围'), findsWidgets);
  });
}
