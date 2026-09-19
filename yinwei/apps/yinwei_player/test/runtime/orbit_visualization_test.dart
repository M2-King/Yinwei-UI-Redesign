import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/widgets/island_spatial_controller.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

import '../fake_window_chrome.dart';

void main() {
  test('orbit telemetry message carries live az/el without a scene snapshot', () {
    final bridge = SpatialSceneBridge(adapter: SpatialRuntimeAdapter());
    final rev = bridge.adapter.appliedRevision;
    bridge.observePlaybackTelemetry(
      playhead: 0.2,
      playing: true,
      orbiting: true,
      azimuthDeg: 40,
      elevationDeg: -8,
    );
    expect(bridge.adapter.appliedRevision, rev);
    final msg = bridge.playbackTelemetryMessage();
    expect(msg['type'], 'playbackTelemetry');
    expect(msg['orbiting'], isTrue);
    expect(msg['azimuthDeg'], 40);
    expect(msg['elevationDeg'], -8);
    expect(msg.containsKey('scene'), isFalse);
    expect(msg.containsKey('revision'), isFalse);
  });

  test('renderer overlay follows orbit telemetry without recreating objects', () {
    final registry = SpatialRendererRegistry();
    registry.applySceneSnapshot({
      'listener': {
        'id': 'listener-0',
        'worldPosition': {'x': 0, 'y': 0, 'z': 0},
      },
      'sources': [
        {
          'id': 'source-main',
          'worldPosition': {'x': 0, 'y': 0, 'z': -2},
        },
      ],
      'emitters': [
        {
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
      ],
    });
    final before = registry.positionOf('source-main')!;
    registry.applyPlaybackTelemetry({
      'playing': true,
      'orbiting': true,
      'azimuthDeg': 90,
      'elevationDeg': 0,
    });
    expect(registry.createCount('source-main'), 1);
    expect(registry.rebuildSpeakers, 0);
    final after = registry.positionOf('source-main')!;
    expect((after['x'] as num).toDouble(), closeTo(2, 1e-6));
    expect((after['z'] as num).toDouble(), closeTo(0, 1e-6));
    expect(before['x'], isNot(after['x']));
  });

  test('orbit visual pose uses telemetry while SceneStore stays put', () {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 2));
    final scenePose = IslandPointIntent.pose(adapter.snapshot()!);
    expect(scenePose.azimuthDeg, closeTo(0, 1e-8));
    final visual = OrbitVisualPose.resolve(
      scenePose: scenePose,
      telemetry: const PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: 90,
        elevationDeg: -10,
      ),
    );
    expect(visual.azimuthDeg, closeTo(90, 1e-8));
    expect(visual.elevationDeg, closeTo(-10, 1e-8));
    expect(visual.distanceM, closeTo(scenePose.distanceM, 1e-8));
    expect(IslandPointIntent.pose(adapter.snapshot()!).azimuthDeg, closeTo(0, 1e-8));
    expect(adapter.appliedRevision, 1);
  });

  test('orbit play moves live azimuth without SceneStore or extra engine writes',
      () async {
    final ctrl = EngineController(engine: MockEngine());
    addTearDown(ctrl.dispose);
    await ctrl.setParams(
      ctrl.params.copy()
        ..motion = MotionMode.orbit
        ..orbitHz = 1
        ..azimuthDeg = 0
        ..elevationDeg = 0,
    );
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    final rev = adapter.appliedRevision;
    await ctrl.play();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final writes = ctrl.nativeSpatialWrites;
    final az0 = ctrl.azimuthDeg;
    await Future<void>.delayed(const Duration(milliseconds: 280));
    expect((ctrl.azimuthDeg - az0).abs(), greaterThan(20));
    expect(adapter.appliedRevision, rev);
    expect(ctrl.nativeSpatialWrites, writes);
    await ctrl.pause();
    final paused = ctrl.azimuthDeg;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(ctrl.azimuthDeg, closeTo(paused, 1));
    await ctrl.play();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect((ctrl.azimuthDeg - paused).abs(), greaterThan(10));
  });

  test('overlay is active only for playing Spatial Orbit without Array', () {
    expect(
      OrbitOverlay.active(
        mode: PlaybackMode.spatial,
        motion: MotionMode.orbit,
        playing: true,
        arrayEnabled: false,
      ),
      isTrue,
    );
    expect(
      OrbitOverlay.active(
        mode: PlaybackMode.spatial,
        motion: MotionMode.orbit,
        playing: false,
        arrayEnabled: false,
      ),
      isFalse,
    );
    expect(
      OrbitOverlay.active(
        mode: PlaybackMode.spatial,
        motion: MotionMode.orbit,
        playing: true,
        arrayEnabled: true,
      ),
      isFalse,
    );
    expect(
      OrbitOverlay.active(
        mode: PlaybackMode.original,
        motion: MotionMode.orbit,
        playing: true,
        arrayEnabled: false,
      ),
      isFalse,
    );
    expect(
      OrbitOverlay.active(
        mode: PlaybackMode.spatial,
        motion: MotionMode.fixed,
        playing: true,
        arrayEnabled: false,
      ),
      isFalse,
    );
  });

  test('visible heading inverse-transforms to origin without double rotation', () {
    const elapsed = Duration(milliseconds: 250);
    const orbitHz = 1.0;
    expect(OrbitPoseMath.phaseDeg(elapsed: elapsed, orbitHz: orbitHz), 90);
    expect(
      OrbitPoseMath.visualFromOrigin(originDeg: 0, elapsed: elapsed, orbitHz: orbitHz),
      closeTo(90, 1e-9),
    );
    expect(
      OrbitPoseMath.originFromVisual(visualDeg: 120, elapsed: elapsed, orbitHz: orbitHz),
      closeTo(30, 1e-9),
    );
    expect(
      OrbitPoseMath.visualFromOrigin(originDeg: 30, elapsed: elapsed, orbitHz: orbitHz),
      closeTo(120, 1e-9),
    );
    final later = OrbitPoseMath.visualFromOrigin(
      originDeg: 30,
      elapsed: const Duration(milliseconds: 500),
      orbitHz: orbitHz,
    );
    expect(later, closeTo(-150, 1e-9));
  });

  test('pause freezes last polled live pose and leaves SceneStore origin', () async {
    final ctrl = EngineController(engine: MockEngine());
    addTearDown(ctrl.dispose);
    await ctrl.setParams(
      ctrl.params.copy()
        ..motion = MotionMode.orbit
        ..orbitHz = 1
        ..azimuthDeg = 0
        ..elevationDeg = -8,
    );
    await ctrl.play();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final formula = ctrl.params.visualAzimuthDeg(ctrl.position);
    final live = wrapAzimuthDeg(formula + 37);
    ctrl.azimuthDeg = live;
    await ctrl.pause();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ctrl.azimuthDeg, closeTo(live, 1e-9));
    expect(ctrl.params.azimuthDeg, closeTo(0, 1e-9));
    expect(ctrl.params.motion, MotionMode.orbit);
  });

  test('Full host telemetry boundary changes source mesh transform', () {
    final registry = SpatialRendererRegistry();
    registry.applySceneSnapshot({
      'listener': {
        'id': 'listener-0',
        'worldPosition': {'x': 0, 'y': 0, 'z': 0},
      },
      'sources': [
        {
          'id': 'source-main',
          'worldPosition': {'x': 0, 'y': 0, 'z': -2},
        },
      ],
    });
    registry.applyPlaybackTelemetry({
      'playing': true,
      'orbiting': true,
      'azimuthDeg': 20,
      'elevationDeg': 0,
    });
    final t0 = Map<String, dynamic>.from(registry.positionOf('source-main')!);
    registry.applyPlaybackTelemetry({
      'playing': true,
      'orbiting': true,
      'azimuthDeg': 80,
      'elevationDeg': 0,
    });
    final t1 = registry.positionOf('source-main')!;
    expect((t0['x'] as num).toDouble(), isNot(closeTo((t1['x'] as num).toDouble(), 1e-6)));
    expect((t0['z'] as num).toDouble(), isNot(closeTo((t1['z'] as num).toDouble(), 1e-6)));
    final frozen = Map<String, dynamic>.from(t1);
    registry.applySceneSnapshot({
      'listener': {
        'id': 'listener-0',
        'worldPosition': {'x': 0, 'y': 0, 'z': 0},
      },
      'sources': [
        {
          'id': 'source-main',
          'worldPosition': {'x': 0, 'y': 0, 'z': -2},
        },
      ],
    });
    final skipped = registry.positionOf('source-main')!;
    expect((skipped['x'] as num).toDouble(), closeTo((frozen['x'] as num).toDouble(), 1e-9));
    expect(registry.createCount('source-main'), 1);
  });

  test('Point drag during Orbit stores inverse origin and keeps live heading',
      () async {
    const elapsed = Duration(milliseconds: 250);
    const orbitHz = 1.0;
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(
        azimuthDeg: 0,
        elevationDeg: 0,
        distanceM: 2,
        motion: MotionMode.orbit,
        orbitHz: orbitHz,
      ));
    final visual = const SphericalV1(
      azimuthDeg: 120,
      elevationDeg: 5,
      distanceM: 2,
    );
    final raw = IslandPointIntent.commit(adapter.snapshot()!, visual);
    final rewritten = OrbitPoseMath.rewritePointIntent(
      raw: raw,
      scene: adapter.snapshot()!,
      elapsed: elapsed,
      orbitHz: orbitHz,
      overlayActive: true,
    );
    final result = SpatialSceneBridge(adapter: adapter).handleMessage(rewritten);
    expect(result.accepted, isTrue);
    expect(result.engineParams!.azimuthDeg, closeTo(30, 1e-6));
    expect(result.engineParams!.elevationDeg, closeTo(5, 1e-6));
    expect(IslandPointIntent.pose(adapter.snapshot()!).azimuthDeg, closeTo(30, 1e-6));
    final live = OrbitVisualPose.resolve(
      scenePose: IslandPointIntent.pose(adapter.snapshot()!),
      telemetry: const PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: 120,
        elevationDeg: 5,
      ),
    );
    expect(live.azimuthDeg, closeTo(120, 1e-6));
    expect(adapter.appliedRevision, 2);

    final ctrl = EngineController(engine: MockEngine());
    addTearDown(ctrl.dispose);
    await ctrl.setParams(
      ctrl.params.copy()
        ..motion = MotionMode.orbit
        ..orbitHz = orbitHz
        ..azimuthDeg = 30
        ..elevationDeg = 5,
    );
    ctrl.position = elapsed;
    ctrl.playing = true;
    ctrl.azimuthDeg = ctrl.params.visualAzimuthDeg(elapsed);
    expect(ctrl.azimuthDeg, closeTo(120, 1e-6));
    await Future<void>.delayed(const Duration(milliseconds: 1));
    ctrl.position = const Duration(milliseconds: 500);
    ctrl.azimuthDeg = ctrl.params.visualAzimuthDeg(ctrl.position);
    expect(ctrl.azimuthDeg, closeTo(-150, 1e-6));
    expect(ctrl.params.azimuthDeg, closeTo(30, 1e-6));
  });

  test('workspace host telemetry payload includes live pose fields', () async {
    final dart =
        await File('lib/widgets/spatial_workspace.dart').readAsString();
    expect(dart.contains('_telemetryMessage() => _tel.toHostMessage()'), isTrue);
    final bridge =
        await File('lib/runtime/spatial_scene_bridge.dart').readAsString();
    expect(bridge.contains("'azimuthDeg': azimuthDeg"), isTrue);
    expect(bridge.contains("'elevationDeg': elevationDeg"), isTrue);
  });

  test('Three.js telemetry overlay moves the source without posting intents',
      () async {
    final js =
        await File('assets/spatial_workspace/scene.js').readAsString();
    expect(js.contains('applyPlaybackTelemetry'), isTrue);
    final body = RegExp(
      r'function applyPlaybackTelemetry[\s\S]*?function applyUiState',
    ).firstMatch(js)!.group(0)!;
    expect(body.contains('next.azimuthDeg'), isTrue);
    expect(body.contains('next.elevationDeg'), isTrue);
    expect(body.contains('poseToXyz'), isTrue);
    expect(body.contains('postToHost'), isFalse);
  });

  testWidgets('Island Point pad follows orbit telemetry without SceneStore writes',
      (tester) async {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 2));
    const tel = PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 90,
      elevationDeg: -10,
    );
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 360,
          height: 300,
          child: IslandSpatialController(
            sceneSnapshot: () => adapter.snapshot()!,
            playbackTelemetry: tel,
            onSceneIntent: (_) => const SceneBridgeResult(),
            onClose: () {},
          ),
        ),
      ),
    ));
    expect(find.text('90°'), findsWidgets);
    expect(find.text('-10°'), findsOneWidget);
    expect(adapter.appliedRevision, 1);
    expect(IslandPointIntent.pose(adapter.snapshot()!).azimuthDeg, closeTo(0, 1e-8));
  });

  testWidgets('Island heading changes across telemetry ticks without SceneStore writes',
      (tester) async {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 2));
    var tel = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 18,
      elevationDeg: 0,
    );
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 360,
          height: 300,
          child: StatefulBuilder(
            builder: (context, setState) => IslandSpatialController(
              sceneSnapshot: () => adapter.snapshot()!,
              playbackTelemetry: tel,
              onSceneIntent: (_) => const SceneBridgeResult(),
              onClose: () {},
            ),
          ),
        ),
      ),
    ));
    expect(find.text('18°'), findsWidgets);
    tel = const PlaybackTelemetryV1(
      playing: true,
      orbiting: true,
      azimuthDeg: 64,
      elevationDeg: 0,
    );
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 360,
          height: 300,
          child: IslandSpatialController(
            sceneSnapshot: () => adapter.snapshot()!,
            playbackTelemetry: tel,
            onSceneIntent: (_) => const SceneBridgeResult(),
            onClose: () {},
          ),
        ),
      ),
    ));
    expect(find.text('64°'), findsWidgets);
    expect(find.text('18°'), findsNothing);
    expect(IslandPointIntent.pose(adapter.snapshot()!).azimuthDeg, closeTo(0, 1e-8));
    expect(adapter.appliedRevision, 1);
  });

  testWidgets('Full and Island follow changing live heading across window modes',
      (tester) async {
    final engine = EngineController(engine: MockEngine());
    final window = WindowModeController(chrome: FakeWindowChrome());
    addTearDown(() {
      engine.dispose();
      window.dispose();
    });
    engine.params
      ..motion = MotionMode.orbit
      ..orbitHz = 1
      ..azimuthDeg = 0
      ..elevationDeg = 0;
    engine.hasOpenedFile = true;
    engine.playing = true;
    engine.azimuthDeg = 22;
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: PlayerScreen(controller: engine, windowMode: window),
    ));
    await tester.pump();
    final rev = tester
        .widget<SpatialWorkspace>(find.byType(SpatialWorkspace))
        .sceneSnapshot!['revision'];
    expect(
      tester.widget<OrbitVisualizer>(find.byType(OrbitVisualizer)).azimuthDeg,
      closeTo(22, 1e-6),
    );
    engine.azimuthDeg = 71;
    engine.notifyListeners();
    await tester.pump();
    expect(
      tester.widget<OrbitVisualizer>(find.byType(OrbitVisualizer)).azimuthDeg,
      closeTo(71, 1e-6),
    );
    expect(
      tester
          .widget<SpatialWorkspace>(find.byType(SpatialWorkspace))
          .playbackTelemetry!
          .value
          .orbiting,
      isTrue,
    );

    await window.enterIsland();
    await window.expandIsland();
    window.setMiniOpen(true);
    await tester.pump();
    expect(find.byType(IslandSpatialController), findsOneWidget);
    expect(find.text('71°'), findsWidgets);
    engine.azimuthDeg = 103;
    engine.notifyListeners();
    await tester.pump();
    expect(find.text('103°'), findsWidgets);

    await window.enterFull();
    await tester.pump();
    final full = tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace));
    expect(full.playbackTelemetry!.value.orbiting, isTrue);
    expect(full.playbackTelemetry!.value.azimuthDeg, closeTo(103, 1e-6));
    expect(full.sceneSnapshot!['revision'], rev);
    expect(
      tester.widget<OrbitVisualizer>(find.byType(OrbitVisualizer)).azimuthDeg,
      closeTo(103, 1e-6),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stopped Orbit does not overlay playhead-derived heading',
      (tester) async {
    final engine = EngineController(engine: MockEngine());
    addTearDown(engine.dispose);
    engine.params
      ..motion = MotionMode.orbit
      ..orbitHz = 1
      ..azimuthDeg = 12
      ..elevationDeg = 0;
    engine.position = const Duration(milliseconds: 250);
    engine.playing = false;
    engine.azimuthDeg = 12;
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: PlayerScreen(controller: engine),
    ));
    await tester.pump();
    final tel = tester
        .widget<SpatialWorkspace>(find.byType(SpatialWorkspace))
        .playbackTelemetry!
        .value;
    expect(tel.orbiting, isFalse);
    expect(tel.azimuthDeg, closeTo(12, 1e-6));
    expect(engine.params.visualAzimuthDeg(engine.position), closeTo(102, 1));
    expect(
      tester.widget<OrbitVisualizer>(find.byType(OrbitVisualizer)).orbiting,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
