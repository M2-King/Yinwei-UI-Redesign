import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/widgets/app_rail.dart';

void main() {
  testWidgets('macOS M1 rail hides unported island and Windows update actions',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppRail(
          onOpen: () {},
          onOpenEq: () {},
          onExport: () {},
          onEnterIsland: null,
          buildId: 'macos-m1',
        ),
      ),
    ));
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Island'), findsNothing);
    expect(find.text('Check updates'), findsNothing);
  });
}
