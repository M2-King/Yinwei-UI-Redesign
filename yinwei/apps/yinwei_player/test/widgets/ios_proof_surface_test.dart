import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/ios_proof_surface.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS capability profile uses the compact proof surface',
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

    expect(find.byType(IosProofSurface), findsOneWidget);
    expect(find.textContaining('音围'), findsWidgets);
    expect(find.textContaining('Yinwei'), findsWidgets);
    expect(find.byType(OrbitVisualizer), findsOneWidget);
    expect(find.text('Array'), findsNothing);
  });

  testWidgets('iOS proof surface shows native vs mock engine honestly',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: IosProofSurface(
          controller: EngineController(),
          backend: EngineBackend.mock,
          loadError: 'symbols missing',
        ),
      ),
    );

    expect(find.textContaining('Mock'), findsWidgets);
    expect(find.textContaining('FFI'), findsWidgets);
  });
}
