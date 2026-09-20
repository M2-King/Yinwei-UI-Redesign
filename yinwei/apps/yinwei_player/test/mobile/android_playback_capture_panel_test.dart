import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/mobile/android_playback_capture_panel.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _FakeAndroidProbe implements AndroidPlaybackCapture {
  _FakeAndroidProbe(this.status);

  AndroidPlaybackCaptureStatus status;
  int starts = 0;
  int stops = 0;

  @override
  bool get supported => status.supported;

  @override
  Future<bool> isAvailable() async => status.supported;

  @override
  Future<void> requestAndStartCapture() async {
    starts += 1;
    status = const AndroidPlaybackCaptureStatus(
      supported: true,
      androidSdk: 34,
      projectionGranted: false,
      captureActive: false,
      foregroundServiceRunning: false,
      audioRecordState: 'UNINITIALIZED',
      readCount: 0,
      capturedFrames: 0,
      silent: false,
      receivingPlaybackAudio: false,
      permissionPending: true,
    );
  }

  @override
  Future<void> stopCapture() async {
    stops += 1;
    status = const AndroidPlaybackCaptureStatus(
      supported: true,
      androidSdk: 34,
      projectionGranted: false,
      captureActive: false,
      foregroundServiceRunning: false,
      audioRecordState: 'STOPPED',
      readCount: 0,
      capturedFrames: 0,
      silent: false,
      receivingPlaybackAudio: false,
      permissionCancelled: true,
    );
  }

  @override
  Future<AndroidPlaybackCaptureStatus> getStatus() async => status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android probe panel maps waiting and cancellation without Error',
      (tester) async {
    final probe = _FakeAndroidProbe(
      const AndroidPlaybackCaptureStatus(
        supported: true,
        androidSdk: 34,
        projectionGranted: false,
        captureActive: false,
        foregroundServiceRunning: false,
        audioRecordState: 'UNINITIALIZED',
        readCount: 0,
        capturedFrames: 0,
        silent: false,
        receivingPlaybackAudio: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(body: AndroidPlaybackCapturePanel(probe: probe)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Live Transfer — Android PoC'), findsOneWidget);
    expect(find.text('Start Capture'), findsOneWidget);
    expect(find.text('Stop Capture'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-playback-capture-start')));
    await tester.pump();
    await tester.pump();
    expect(probe.starts, 1);
    expect(find.text('Waiting for Android permission'), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-playback-capture-stop')));
    await tester.pump();
    await tester.pump();
    expect(probe.stops, 1);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Error'), findsNothing);
  });

  testWidgets('Android screen keeps Open file playback beside the capture probe',
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
          capabilities: PlatformCapabilities.android,
          sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
          telemetry: ValueNotifier(const PlaybackTelemetryV1()),
          onSceneIntent: bridge.handleMessage,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('android-playback-capture')), findsOneWidget);
    expect(find.byKey(const Key('ios-screen-audio-probe')), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    addTearDown(controller.dispose);
  });

  testWidgets('Android capability profile uses the mobile player with the A1 probe',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ctrl = EngineController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.android,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MobilePlayerScreen), findsOneWidget);
    expect(find.byKey(const Key('android-playback-capture')), findsOneWidget);
    expect(find.text('Live Transfer — Android PoC'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}
