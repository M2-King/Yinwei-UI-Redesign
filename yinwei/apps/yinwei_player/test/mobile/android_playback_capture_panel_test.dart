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
    expect(find.text('Live Transfer — Android A2'), findsOneWidget);
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

  testWidgets('Android A2 panel shows DSP counters and no wet output',
      (tester) async {
    final probe = _FakeAndroidProbe(
      const AndroidPlaybackCaptureStatus(
        supported: true,
        androidSdk: 34,
        projectionGranted: true,
        captureActive: true,
        foregroundServiceRunning: true,
        audioRecordState: 'RECORDING',
        readCount: 404,
        capturedFrames: 827392,
        sampleRate: 48000,
        channelCount: 2,
        encoding: 'PCM_FLOAT',
        rmsDb: -13.0,
        peakDb: -1.3,
        silent: false,
        receivingPlaybackAudio: true,
        dspLibraryLoaded: true,
        dspState: 'Processing',
        nativeInputFrames: 827392,
        nativeConsumedFrames: 826880,
        nativeDspChunks: 1615,
        nativeWetFrames: 826880,
        nativeQueueDepthFrames: 512,
        nativeDroppedFrames: 0,
        nativeWetRmsDb: -15.2,
        nativeWetPeakDb: -2.4,
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
    expect(find.text('Receiving Playback Audio'), findsOneWidget);
    expect(find.textContaining('DSP:'), findsOneWidget);
    expect(find.textContaining('Processing · spatial_core'), findsOneWidget);
    expect(find.textContaining('Input: 827392'), findsOneWidget);
    expect(find.textContaining('Wet RMS: -15.2 dB'), findsOneWidget);
    expect(find.textContaining('NO WET OUTPUT YET'), findsOneWidget);
  });

  testWidgets(
      'Android probe panel shows capture-only instruction and native hint',
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
        permissionCancelled: true,
        captureHint: 'Screen audio not granted — tap Start Capture',
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
    expect(
      find.text(
        'NO WET OUTPUT YET · spatial_core HRTF is measured, not played.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Screen audio not granted — tap Start Capture'),
      findsOneWidget,
    );
    expect(find.text('Error'), findsNothing);
  });

  testWidgets(
      'Android screen keeps Open file playback beside the capture probe',
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

  testWidgets('Android A2 HUD does not present file-engine mock as FAILED',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = EngineController(
      backendLabel: 'Android A2 · file engine preview · not connected',
    );
    addTearDown(controller.dispose);
    final adapter = SpatialRuntimeAdapter()..bootstrap(controller.params);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: MobilePlayerScreen(
          controller: controller,
          backend: EngineBackend.mock,
          loadError:
              'Bad state: spatial_core is not connected on Android A2 file-engine preview',
          capabilities: PlatformCapabilities.android,
          sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
          telemetry: ValueNotifier(const PlaybackTelemetryV1()),
          onSceneIntent: SpatialSceneBridge(adapter: adapter).handleMessage,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('File engine: Preview / not connected'),
        findsOneWidget);
    expect(find.textContaining('Engine: FAILED'), findsNothing);
    expect(find.textContaining('Native: ERROR'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Start Capture'), findsOneWidget);
    expect(find.textContaining('NO WET OUTPUT YET'), findsOneWidget);
  });

  testWidgets(
      'Android capability profile uses the mobile player with the A1 probe',
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
    expect(find.text('Live Transfer — Android A2'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}
