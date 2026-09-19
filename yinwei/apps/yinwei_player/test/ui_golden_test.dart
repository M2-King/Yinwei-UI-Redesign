import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

void main() {
  testWidgets('player UI dark field golden', (tester) async {
    final ctrl = EngineController(
      engine: MockEngine(),
      backendLabel: 'Native · spatial_core',
    );
    ctrl.hasOpenedFile = true; // The golden depicts a loaded, paused track.
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/player_ui_dark_field.png'),
    );
  });
}
