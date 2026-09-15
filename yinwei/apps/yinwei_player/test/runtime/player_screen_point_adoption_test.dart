import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

void main() {
  testWidgets('Point presets update EngineController through Scene adoption',
      (tester) async {
    final ctrl = EngineController(
      engine: MockEngine(),
      backendLabel: 'Mock',
    );
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.ensureVisible(find.text('Front'));
    await tester.tap(find.text('Front'));
    await tester.pump();
    expect(ctrl.params.azimuthDeg, closeTo(0, 1e-4));
    expect(ctrl.array.enabled, isFalse);

    await tester.tap(find.text('Left'));
    await tester.pump();
    expect(ctrl.params.azimuthDeg, closeTo(-90, 1e-4));

    await tester.tap(find.text('Right'));
    await tester.pump();
    expect(ctrl.params.azimuthDeg, closeTo(90, 1e-4));

    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(ctrl.params.azimuthDeg.abs(), closeTo(180, 1e-4));
    expect(ctrl.array.enabled, isFalse);

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
