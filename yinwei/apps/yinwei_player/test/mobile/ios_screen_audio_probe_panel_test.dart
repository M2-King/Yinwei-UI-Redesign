import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/mobile/ios_screen_audio_probe_panel.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _FakeProbe implements ScreenAudioProbe {
  _FakeProbe(this.status);

  ScreenAudioProbeStatus status;
  int starts = 0;
  int stops = 0;

  @override
  bool get supported => status.supported;

  @override
  Future<bool> isAvailable() async => status.supported;

  @override
  Future<void> startCapture() async {
    starts += 1;
    status = ScreenAudioProbeStatus(
      supported: true,
      captureActive: false,
      pickerActive: true,
      audioBufferCount: 0,
      microphoneBufferCount: 0,
      screenBufferCount: 0,
      receivingSystemAudio: false,
      receivingMicrophone: false,
      audioSilent: false,
      pickerCancelled: false,
      excludesCurrentProcessAudioSupported: true,
      excludesCurrentProcessAudio: true,
    );
  }

  @override
  Future<void> stopCapture() async {
    stops += 1;
    status = ScreenAudioProbeStatus(
      supported: true,
      captureActive: false,
      pickerActive: false,
      audioBufferCount: 0,
      microphoneBufferCount: 0,
      screenBufferCount: 0,
      receivingSystemAudio: false,
      receivingMicrophone: false,
      audioSilent: false,
      pickerCancelled: false,
      excludesCurrentProcessAudioSupported: true,
      excludesCurrentProcessAudio: true,
    );
  }

  @override
  Future<ScreenAudioProbeStatus> getStatus() async => status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probe panel maps waiting and cancellation without Error',
      (tester) async {
    final probe = _FakeProbe(
      const ScreenAudioProbeStatus(
        supported: true,
        captureActive: false,
        pickerActive: false,
        audioBufferCount: 0,
        microphoneBufferCount: 0,
        screenBufferCount: 0,
        receivingSystemAudio: false,
        receivingMicrophone: false,
        audioSilent: false,
        pickerCancelled: false,
        excludesCurrentProcessAudioSupported: true,
        excludesCurrentProcessAudio: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(body: IosScreenAudioProbePanel(probe: probe)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Live Transfer — iOS 27 PoC'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ios-screen-audio-probe-start')));
    await tester.pump();
    await tester.pump();
    expect(probe.starts, 1);
    expect(find.text('Waiting for Apple Picker'), findsOneWidget);

    probe.status = ScreenAudioProbeStatus(
      supported: true,
      captureActive: false,
      pickerActive: false,
      audioBufferCount: 0,
      microphoneBufferCount: 0,
      screenBufferCount: 0,
      receivingSystemAudio: false,
      receivingMicrophone: false,
      audioSilent: false,
      pickerCancelled: true,
      excludesCurrentProcessAudioSupported: true,
      excludesCurrentProcessAudio: true,
    );
    await tester.tap(find.byKey(const Key('ios-screen-audio-probe-stop')));
    await tester.pump();
    await tester.pump();
    expect(probe.stops, 1);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Error'), findsNothing);
  });

  testWidgets('iPhone screen keeps Open file playback beside the probe',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = EngineController();
    final adapter = SpatialRuntimeAdapter();
    adapter.bootstrap(controller.params);
    final bridge = SpatialSceneBridge(adapter: adapter);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: MobilePlayerScreen(
          controller: controller,
          backend: EngineBackend.mock,
          capabilities: PlatformCapabilities.ios,
          sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
          telemetry: ValueNotifier(const PlaybackTelemetryV1()),
          onSceneIntent: bridge.handleMessage,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('ios-screen-audio-probe')), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    addTearDown(controller.dispose);
  });
}
