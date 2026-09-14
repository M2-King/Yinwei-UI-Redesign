import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';

void main() {
  testWidgets('Point|2.0 switch is hidden when array is unsupported',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            arraySupported: false,
            onChanged: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('点源'), findsNothing);
    expect(find.text('2.0'), findsNothing);
    expect(find.text('5.1'), findsNothing);
  });

  testWidgets('2.0 mode shows L/R chips and pose sliders, not 5.1',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: ArrayLayout.stereo2(),
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('点源'), findsOneWidget);
    expect(find.text('2.0'), findsOneWidget);
    expect(find.text('5.1'), findsNothing);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    expect(find.text('Azimuth'), findsOneWidget);
    expect(find.text('Center'), findsNothing);
    expect(find.text('Surround'), findsNothing);
    expect(find.text('LFE'), findsNothing);
  });
}
