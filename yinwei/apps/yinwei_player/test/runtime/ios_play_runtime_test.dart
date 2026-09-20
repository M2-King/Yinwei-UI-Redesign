import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/platform/audio_session_coordinator.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _TraceEngine extends MockEngine {
  _TraceEngine(this.trace);
  final List<String> trace;

  @override
  Future<void> play() async {
    trace.add('play');
    await super.play();
  }

  @override
  Future<TrackMeta> open(String path) async {
    trace.add('open:$path');
    return super.open(path);
  }
}

class _FailingPlayEngine extends MockEngine {
  @override
  Future<void> play() async {
    throw StateError('AudioDevice: no default output device');
  }
}

class _FailingOpenEngine extends MockEngine {
  @override
  Future<TrackMeta> open(String path) async {
    throw StateError('FileNotFound: $path');
  }

  @override
  Future<void> play() async {
    throw StateError('play must not run after a failed open');
  }
}

class _TraceSession implements AudioSessionCoordinator {
  _TraceSession(this.trace);
  final List<String> trace;

  @override
  bool get available => true;

  @override
  Future<void> activateForPlayback() async {
    trace.add('session');
  }

  @override
  Future<void> deactivate() async {
    trace.add('deactivate');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  FilledButton playButton(WidgetTester tester) {
    return tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Play'),
    );
  }

  testWidgets('iOS Play activates AVAudioSession before the engine starts',
      (tester) async {
    await phone(tester);
    final trace = <String>[];
    final ctrl = EngineController(
      engine: _TraceEngine(trace),
      backendLabel: 'Native · spatial_core',
    )..hasOpenedFile = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          audioSession: _TraceSession(trace),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(trace, ['session', 'play']);
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('failed native play releases the audio session', (tester) async {
    await phone(tester);
    final trace = <String>[];
    final ctrl = EngineController(
      engine: _FailingPlayEngine(),
      backendLabel: 'Native · spatial_core',
    )..hasOpenedFile = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          audioSession: _TraceSession(trace),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(trace, ['session', 'deactivate']);
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, contains('AudioDevice'));
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('Play with no file loaded does not call engine.play',
      (tester) async {
    await phone(tester);
    final trace = <String>[];
    final ctrl = EngineController(
      engine: _TraceEngine(trace),
      backendLabel: 'Native · spatial_core',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          audioSession: _TraceSession(trace),
        ),
      ),
    );
    await tester.pump();

    expect(playButton(tester).onPressed, isNull);
    await tester.tap(find.text('Play'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(trace.contains('play'), isFalse);
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, isNull);
    expect(find.textContaining('NoTrackLoaded'), findsNothing);
    expect(find.text('Across the Room'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('successful open enables Play and refreshes the loaded track',
      (tester) async {
    await phone(tester);
    final trace = <String>[];
    final ctrl = EngineController(
      engine: _TraceEngine(trace),
      backendLabel: 'Native · spatial_core',
    )..lastError = 'Bad state: NoTrackLoaded: no track loaded';

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          audioSession: _TraceSession(trace),
          pickPlaybackFile: () async => '/tmp/point-source.wav',
        ),
      ),
    );
    await tester.pump();
    expect(playButton(tester).onPressed, isNull);

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(ctrl.hasOpenedFile, isTrue);
    expect(ctrl.track.title, 'point-source');
    expect(ctrl.lastError, isNull);
    expect(playButton(tester).onPressed, isNotNull);
    expect(find.textContaining('NoTrackLoaded'), findsNothing);
    expect(find.textContaining('point-source'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('cancelling Open stays stopped with no error', (tester) async {
    await phone(tester);
    final trace = <String>[];
    final ctrl = EngineController(
      engine: _TraceEngine(trace),
      backendLabel: 'Native · spatial_core',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          audioSession: _TraceSession(trace),
          pickPlaybackFile: () async => null,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(trace, isEmpty);
    expect(ctrl.hasOpenedFile, isFalse);
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, isNull);
    expect(find.byType(SnackBar), findsNothing);
    expect(playButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('native open failure remains visible and Play stays unavailable',
      (tester) async {
    await phone(tester);
    final ctrl = EngineController(
      engine: _FailingOpenEngine(),
      backendLabel: 'Native · spatial_core',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: PlatformCapabilities.ios,
          pickPlaybackFile: () async => 'missing.wav',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(ctrl.hasOpenedFile, isFalse);
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, contains('FileNotFound'));
    expect(playButton(tester).onPressed, isNull);
    expect(find.textContaining('FileNotFound'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    ctrl.dispose();
  });

  testWidgets('iOS HUD does not report Mock as a live native engine',
      (tester) async {
    await phone(tester);
    final ctrl = EngineController();
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    final telemetry = ValueNotifier(const PlaybackTelemetryV1());
    addTearDown(ctrl.dispose);
    addTearDown(telemetry.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: MobilePlayerScreen(
          controller: ctrl,
          backend: EngineBackend.mock,
          loadError: 'Failed to lookup symbol (yinwei_open)',
          capabilities: PlatformCapabilities.ios,
          sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
          telemetry: telemetry,
          onSceneIntent: SpatialSceneBridge(adapter: adapter).handleMessage,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('ios-runtime-status')), findsOneWidget);
    expect(find.textContaining('Engine: FAILED'), findsOneWidget);
    expect(find.textContaining('Native: ERROR'), findsOneWidget);
    expect(find.textContaining('Audio: STOPPED'), findsOneWidget);
  });

  testWidgets('iOS HUD reports native audio running only while playing',
      (tester) async {
    await phone(tester);
    final ctrl = EngineController(backendLabel: 'Native · spatial_core')
      ..hasOpenedFile = true
      ..playing = true;
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    final telemetry = ValueNotifier(const PlaybackTelemetryV1(playing: true));
    addTearDown(ctrl.dispose);
    addTearDown(telemetry.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: MobilePlayerScreen(
          controller: ctrl,
          backend: EngineBackend.native,
          capabilities: PlatformCapabilities.ios,
          sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
          telemetry: telemetry,
          onSceneIntent: SpatialSceneBridge(adapter: adapter).handleMessage,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Engine: READY'), findsOneWidget);
    expect(find.textContaining('Native: CONNECTED'), findsOneWidget);
    expect(find.textContaining('Audio: RUNNING'), findsOneWidget);
  });
}
