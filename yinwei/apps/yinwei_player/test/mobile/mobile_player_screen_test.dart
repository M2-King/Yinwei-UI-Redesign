import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/mobile/mobile_spatial_visualizer.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/app_rail.dart';
import 'package:yinwei_player/widgets/island_bar.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

class _Harness {
  _Harness({SpatialParams? params})
      : controller = EngineController(),
        adapter = SpatialRuntimeAdapter(),
        telemetry = ValueNotifier(const PlaybackTelemetryV1()) {
    if (params != null) {
      controller.params = params;
      controller.azimuthDeg = params.azimuthDeg;
      controller.elevationDeg = params.elevationDeg;
    }
    adapter.bootstrap(controller.params);
    bridge = SpatialSceneBridge(adapter: adapter);
  }

  final EngineController controller;
  final SpatialRuntimeAdapter adapter;
  late final SpatialSceneBridge bridge;
  final ValueNotifier<PlaybackTelemetryV1> telemetry;
  final intents = <String>[];
  int bridgeCommits = 0;

  SceneBridgeResult onSceneIntent(String raw) {
    intents.add(raw);
    final rewritten = OrbitPoseMath.rewritePointIntent(
      raw: raw,
      scene: adapter.snapshot() ?? const <String, dynamic>{},
      elapsed: controller.position,
      orbitHz: controller.params.orbitHz,
      overlayActive: OrbitOverlay.active(
        mode: controller.mode,
        motion: controller.params.motion,
        playing: controller.playing,
        arrayEnabled: controller.array.enabled,
      ),
    );
    final result = bridge.handleMessage(rewritten);
    if (result.shouldWriteEngine) {
      bridgeCommits++;
      controller.setParams(result.engineParams!);
    }
    return result;
  }

  Widget app() {
    return MaterialApp(
      theme: YinweiTheme.dark(),
      home: MobilePlayerScreen(
        controller: controller,
        backend: EngineBackend.mock,
        loadError: 'symbols missing',
        capabilities: PlatformCapabilities.ios,
        sceneSnapshot: () => adapter.snapshot() ?? const <String, dynamic>{},
        telemetry: telemetry,
        onSceneIntent: onSceneIntent,
      ),
    );
  }

  SphericalV1 storePose() => IslandPointIntent.pose(adapter.snapshot()!);

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 40));
    controller.dispose();
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

  testWidgets('iPhone form-factor selects the mobile player surface',
      (tester) async {
    await phone(tester);
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
    expect(find.byType(MobileSpatialVisualizer), findsOneWidget);
    expect(find.byType(AppRail), findsNothing);
    expect(find.byType(IslandBar), findsNothing);
    expect(find.byType(SpatialWorkspace), findsNothing);
    expect(find.byType(OrbitVisualizer), findsNothing);
    expect(find.textContaining('音围'), findsWidgets);
    expect(find.textContaining('Yinwei'), findsWidgets);
    addTearDown(ctrl.dispose);
  });

  test('mobile presentation sources do not require Windows-only services', () {
    final roots = [
      Directory('lib/mobile'),
      Directory('lib/presentation'),
    ];
    final banned = [
      'window_manager',
      'desktop_drop',
      'system_media',
      'live_transfer',
      'win32',
      'WASAPI',
      'WindowManagerChrome',
    ];
    for (final root in roots) {
      expect(root.existsSync(), isTrue, reason: root.path);
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final src = file.readAsStringSync();
        for (final token in banned) {
          expect(
            src.contains(token),
            isFalse,
            reason: '${file.path} must not reference $token',
          );
        }
      }
    }
  });

  testWidgets('Point drag commits through SpatialSceneBridge', (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5),
    );
    await tester.pumpWidget(h.app());
    await tester.pump();

    final viz = tester.getRect(find.byKey(const Key('mobile-spatial-visualizer')));
    await tester.tapAt(viz.center + const Offset(0, -80));
    await tester.pump();

    expect(h.intents, isNotEmpty);
    final decoded = jsonDecode(h.intents.last) as Map;
    expect(decoded['type'], 'sourcePoseCommit');
    expect(decoded['objectId'], kSpatialPointSourceIdV1);
    expect(h.bridgeCommits, greaterThan(0));
    expect(h.storePose().azimuthDeg.abs(), lessThan(25));
    expect(h.controller.params.azimuthDeg.abs(), lessThan(25));
    await h.finish(tester);
  });

  testWidgets('Orbit overlay follows live telemetry', (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(
        azimuthDeg: 0,
        elevationDeg: 0,
        distanceM: 1.5,
        motion: MotionMode.orbit,
      ),
    );
    h.controller.playing = true;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 20,
      elevationDeg: 4,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();
    expect(find.byKey(const Key('mobile-azimuth-readout')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('20'));

    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 67,
      elevationDeg: 4,
    );
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('67'));
    expect(h.storePose().azimuthDeg.abs(), lessThan(1));
    expect(find.byKey(const Key('mobile-orbit-overlay')), findsOneWidget);
    await h.finish(tester);
  });

  testWidgets('pause freezes last live pose', (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(
        azimuthDeg: 0,
        elevationDeg: -10,
        distanceM: 1.5,
        motion: MotionMode.orbit,
      ),
    );
    h.controller.hasOpenedFile = true;
    h.controller.playing = true;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 44,
      elevationDeg: 9,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('44'));

    h.controller.playing = false;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: false,
      orbiting: false,
      azimuthDeg: 0,
      elevationDeg: -10,
    );
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('44'));
    expect(h.storePose().azimuthDeg.abs(), lessThan(1));
    await h.finish(tester);
  });

  testWidgets('resume continues live telemetry', (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(
        azimuthDeg: 0,
        elevationDeg: 0,
        distanceM: 1.5,
        motion: MotionMode.orbit,
      ),
    );
    h.controller.hasOpenedFile = true;
    h.controller.playing = true;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 18,
      elevationDeg: 0,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();

    h.controller.playing = false;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: false,
      orbiting: false,
      azimuthDeg: 0,
    );
    await tester.pump();

    h.controller.playing = true;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 81,
      elevationDeg: 2,
    );
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('81'));
    await h.finish(tester);
  });

  testWidgets('Orbit drag inverse-transforms visual heading to origin',
      (tester) async {
    await phone(tester);
    const elapsed = Duration(milliseconds: 250);
    final h = _Harness(
      params: SpatialParams(
        azimuthDeg: 0,
        elevationDeg: 0,
        distanceM: 1.5,
        motion: MotionMode.orbit,
        orbitHz: 0.4,
      ),
    );
    h.controller.playing = true;
    h.controller.position = elapsed;
    final phase = OrbitPoseMath.phaseDeg(elapsed: elapsed, orbitHz: 0.4);
    h.telemetry.value = PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: phase,
      elevationDeg: 0,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();

    final viz = tester.getRect(find.byKey(const Key('mobile-spatial-visualizer')));
    await tester.tapAt(viz.center + const Offset(0, -80));
    await tester.pump();

    expect(h.intents, isNotEmpty);
    final visual = jsonDecode(h.intents.last) as Map;
    expect(visual['type'], 'sourcePoseCommit');
    final stored = h.storePose();
    expect(stored.azimuthDeg, closeTo(0 - phase, 20));
    expect(stored.azimuthDeg, isNot(closeTo(0, 8)));
    await h.finish(tester);
  });

  testWidgets('Fixed mode uses SceneStore pose', (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(azimuthDeg: -45, elevationDeg: 12, distanceM: 2),
    );
    h.controller.playing = true;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: false,
      azimuthDeg: 90,
      elevationDeg: 0,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('mobile-azimuth-readout'))).data,
        contains('-45'));
    expect(find.byKey(const Key('mobile-orbit-overlay')), findsNothing);
    await h.finish(tester);
  });

  testWidgets('Stereo mode does not consume Point Orbit overlay',
      (tester) async {
    await phone(tester);
    final h = _Harness(
      params: SpatialParams(
        azimuthDeg: 0,
        elevationDeg: 0,
        distanceM: 1.5,
        motion: MotionMode.orbit,
      ),
    );
    h.controller.array = ArrayLayout.stereo2();
    h.controller.playing = true;
    final rev = h.adapter.appliedRevision;
    h.telemetry.value = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 99,
      elevationDeg: 12,
    );
    await tester.pumpWidget(h.app());
    await tester.pump();

    expect(find.byKey(const Key('mobile-stereo-L')), findsOneWidget);
    expect(find.byKey(const Key('mobile-stereo-R')), findsOneWidget);
    expect(find.byKey(const Key('mobile-orbit-overlay')), findsNothing);
    expect(find.textContaining('99'), findsNothing);

    final viz = tester.getRect(find.byKey(const Key('mobile-spatial-visualizer')));
    await tester.tapAt(viz.center + const Offset(0, -80));
    await tester.pump();
    expect(h.intents, isEmpty);
    expect(h.adapter.appliedRevision, rev);
    await h.finish(tester);
  });

  testWidgets('Windows workstation layout is unchanged at desktop size',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ctrl = EngineController();
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(MobilePlayerScreen), findsNothing);
    expect(find.byType(AppRail), findsOneWidget);
    expect(find.byType(SpatialWorkspace), findsOneWidget);
    addTearDown(ctrl.dispose);
  });
}
