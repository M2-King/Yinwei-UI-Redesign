import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';
import 'package:yinwei_player/widgets/system_live_monitor_bar.dart';

void main() {
  testWidgets('macOS M1 Point UI hides unported surfaces and accepts pose input',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine(), backendLabel: 'Mock');
    final captureKey = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: YinweiTheme.dark(),
        debugShowCheckedModeBanner: false,
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.macos,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Island'), findsNothing);
    expect(find.text('Check updates'), findsNothing);
    expect(find.byType(SystemLiveMonitorBar), findsNothing);
    expect(tester.widget<PositionSidebar>(find.byType(PositionSidebar))
        .arraySupported, isTrue);
    await tester.ensureVisible(find.text('Right'));
    await tester.tap(find.text('Right'));
    await tester.pumpAndSettle();
    expect(ctrl.params.azimuthDeg, closeTo(90, 1e-4));
    expect(ctrl.array.enabled, isFalse);
    expect(tester.takeException(), isNull);

    // Optional QA artifact. This is a mocked M1 UI, not a macOS runtime proof.
    final output = Platform.environment['YINWEI_MACOS_UI_CAPTURE'];
    if (output != null) {
      final boundary = captureKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(
            data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
