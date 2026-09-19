import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS capability profile uses the iPhone product surface',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ctrl = EngineController();
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
        ),
      ),
    );

    expect(find.byType(MobilePlayerScreen), findsOneWidget);
    expect(find.textContaining('音围'), findsWidgets);
    expect(find.textContaining('Yinwei'), findsWidgets);
    expect(find.byType(OrbitVisualizer), findsNothing);
    expect(find.text('Array'), findsNothing);
    addTearDown(ctrl.dispose);
  });
}
