import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

Vec3V1 _sourceWorld(Map<String, dynamic> scene) {
  final source = (scene['sources'] as List).cast<Map>().firstWhere(
        (s) => s['id'] == kSpatialPointSourceIdV1,
      );
  final p = source['worldPosition'] as Map;
  return Vec3V1(
    (p['x'] as num).toDouble(),
    (p['y'] as num).toDouble(),
    (p['z'] as num).toDouble(),
  );
}

Map<String, dynamic> _poseIntent({
  required String type,
  required double x,
  required double y,
  required double z,
  required int basedOnRevision,
}) {
  return {
    'type': type,
    'objectId': kSpatialPointSourceIdV1,
    'worldPosition': {'x': x, 'y': y, 'z': z},
    'basedOnRevision': basedOnRevision,
  };
}

/// Desktop workstation contract for this file — not host OS detection.
/// Avoids Win32 chrome, SMTC, WASAPI, and a real Three.js WebView.
const _testDesktopCaps = PlatformCapabilities(
  desktopWindow: true,
  nativeWindowChrome: false,
  floatingIsland: false,
  systemMedia: false,
  liveTransfer: false,
  desktopDrop: false,
  threeJsWebView: false,
  filePlayback: true,
  pointSpatial: true,
  array: true,
);

void main() {
  const trig = 1e-6;

  SpatialSceneBridge boot([SpatialRuntimeAdapter? adapter]) {
    final a = adapter ?? SpatialRuntimeAdapter();
    a.bootstrap(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5),
    );
    return SpatialSceneBridge(adapter: a);
  }

  test('telemetry does not bump scene revision', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    for (var i = 0; i < 40; i++) {
      bridge.observePlaybackTelemetry(
        playhead: i / 40,
        playing: true,
        orbiting: i.isEven,
        envelopment: 0.45,
      );
    }
    expect(bridge.adapter.appliedRevision, rev);
    expect(bridge.adapter.snapshot()!['revision'], rev);
  });

  test('selection does not bump scene revision', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    bridge.handleMessage(jsonEncode({
      'type': 'selectObject',
      'objectId': kSpatialPointSourceIdV1,
    }));
    bridge.handleMessage(jsonEncode({
      'type': 'selectObject',
      'objectId': kSpatialListenerIdV1,
    }));
    expect(bridge.adapter.appliedRevision, rev);
  });

  test('camera movement does not bump scene revision', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    bridge.handleMessage(jsonEncode({
      'type': 'cameraMoved',
      'view': 'top',
    }));
    expect(bridge.adapter.appliedRevision, rev);
  });

  test('seek/play/pause do not bump scene revision', () async {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5));
    final ctrl = EngineController(engine: MockEngine());
    final rev = adapter.appliedRevision;
    await ctrl.play();
    await ctrl.seek(const Duration(seconds: 2));
    await ctrl.pause();
    expect(adapter.appliedRevision, rev);
    expect(adapter.snapshot()!['revision'], rev);
    ctrl.dispose();
  });

  test('preview does not mutate Scene Store or bump revision', () {
    final bridge = boot();
    final before = _sourceWorld(bridge.adapter.snapshot()!);
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 0.2,
      y: 0.1,
      z: -1.4,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(result.sceneMutated, isFalse);
    expect(result.shouldWriteEngine, isTrue);
    expect(bridge.adapter.appliedRevision, 1);
    final after = _sourceWorld(bridge.adapter.snapshot()!);
    expect(after.x, closeTo(before.x, trig));
    expect(after.y, closeTo(before.y, trig));
    expect(after.z, closeTo(before.z, trig));
    expect(result.outgoing.where((m) => m['type'] == 'sceneSnapshot'), isEmpty);
  });

  test('commit after previews writes one authoritative revision', () {
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 0.4,
      y: 0.2,
      z: -1.1,
      basedOnRevision: 1,
    )));
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 0.7,
      y: 0.2,
      z: -1.0,
      basedOnRevision: 1,
    )));
    expect(bridge.adapter.appliedRevision, 1);
    final commit = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 0.7,
      y: 0.2,
      z: -1.0,
      basedOnRevision: 1,
    )));
    expect(commit.accepted, isTrue);
    expect(commit.sceneMutated, isTrue);
    expect(commit.shouldWriteEngine, isTrue);
    expect(bridge.adapter.appliedRevision, 2);
    final world = _sourceWorld(bridge.adapter.snapshot()!);
    expect(world.x, closeTo(0.7, trig));
    expect(world.y, closeTo(0.2, trig));
    expect(world.z, closeTo(-1.0, trig));
    expect(commit.engineParams!.azimuthDeg, closeTo(
      localToSpherical(world).azimuthDeg,
      1e-4,
    ));
  });

  test('stale commit is rejected and cannot rewind scene or engine', () {
    final writes = <SpatialParams>[];
    final bridge = boot();

    void apply(SceneBridgeResult result) {
      if (result.shouldWriteEngine) writes.add(result.engineParams!.copy());
    }

    apply(bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 0,
      y: 0,
      z: -2,
      basedOnRevision: 1,
    ))));
    expect(bridge.adapter.appliedRevision, 2);
    expect(_sourceWorld(bridge.adapter.snapshot()!).z, closeTo(-2, trig));
    final committed = writes.single;

    apply(bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 3,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    ))));
    expect(bridge.adapter.appliedRevision, 2);

    final stale = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 3,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    apply(stale);
    expect(stale.accepted, isFalse);
    expect(stale.reason, 'stale_revision');
    expect(stale.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 2);
    expect(_sourceWorld(bridge.adapter.snapshot()!).z, closeTo(-2, trig));
    expect(writes.last.azimuthDeg, closeTo(committed.azimuthDeg, trig));
    expect(writes.last.distanceM, closeTo(committed.distanceM, trig));
  });

  test('intervening UI mutation makes in-flight drag commit stale', () {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5));
    final bridge = SpatialSceneBridge(adapter: adapter);
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 2),
    );
    expect(adapter.appliedRevision, 2);
    final stale = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 1.5,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(stale.accepted, isFalse);
    expect(stale.shouldWriteEngine, isFalse);
    expect(adapter.appliedRevision, 2);
    expect(_sourceWorld(adapter.snapshot()!).z, closeTo(-2, trig));
  });

  test('rapid successive commits stay monotonic and keep latest pose', () {
    final bridge = boot();
    final poses = <(double, double, double)>[
      (0, 0, -1),
      (1, 0, 0),
      (0, 0.5, -1.5),
    ];
    var basedOn = 1;
    for (final pose in poses) {
      final result = bridge.handleMessage(jsonEncode(_poseIntent(
        type: 'sourcePoseCommit',
        x: pose.$1,
        y: pose.$2,
        z: pose.$3,
        basedOnRevision: basedOn,
      )));
      expect(result.accepted, isTrue);
      basedOn = bridge.adapter.appliedRevision;
    }
    expect(bridge.adapter.appliedRevision, 4);
    final world = _sourceWorld(bridge.adapter.snapshot()!);
    expect(world.x, closeTo(0, trig));
    expect(world.y, closeTo(0.5, trig));
    expect(world.z, closeTo(-1.5, trig));
  });

  test('repeated telemetry does not recreate renderer object identity', () {
    final registry = SpatialRendererRegistry();
    registry.applySceneSnapshot({
      'listener': {
        'id': 'listener-0',
        'worldPosition': {'x': 0, 'y': 0, 'z': 0},
      },
      'sources': [
        {
          'id': 'source-main',
          'worldPosition': {'x': 1, 'y': 0, 'z': 0},
        },
      ],
      'emitters': [
        {
          'id': 'emitter-L',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
      ],
    });
    expect(registry.createCount('source-main'), 1);
    for (var i = 0; i < 30; i++) {
      registry.applyPlaybackTelemetry({
        'playhead': i / 30,
        'playing': true,
      });
      registry.applySceneSnapshot({
        'listener': {
          'id': 'listener-0',
          'worldPosition': {'x': 0, 'y': 0, 'z': 0},
        },
        'sources': [
          {
            'id': 'source-main',
            'worldPosition': {'x': 1, 'y': 0, 'z': 0},
          },
        ],
        'emitters': [
          {
            'id': 'emitter-L',
            'worldPosition': {'x': -1, 'y': 0, 'z': -1},
          },
        ],
      });
    }
    expect(registry.createCount('source-main'), 1);
    expect(registry.createCount('listener-0'), 1);
    expect(registry.createCount('emitter-L'), 1);
    expect(registry.rebuildSpeakers, 0);
  });

  test('idle playback does not issue extra native spatial writes', () async {
    final ctrl = EngineController(engine: MockEngine());
    final before = ctrl.nativeSpatialWrites;
    await ctrl.play();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await ctrl.pause();
    expect(ctrl.nativeSpatialWrites, before);
    expect(ctrl.spatialSetParamsCalls, 0);
    ctrl.dispose();
  });

  test('controlled drag issues UI param writes without scene revision storm', () {
    final adapter = SpatialRuntimeAdapter()
      ..bootstrap(SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5));
    final ctrl = EngineController(engine: MockEngine());
    final writesBefore = ctrl.spatialSetParamsCalls;
    for (var i = 1; i <= 8; i++) {
      final preview = adapter.adoptSourceWorld(
        objectId: kSpatialPointSourceIdV1,
        world: Vec3V1(i * 0.1, 0, -1.2),
        basedOnRevision: 1,
        commit: false,
      );
      expect(preview.sceneMutated, isFalse);
      expect(adapter.appliedRevision, 1);
      if (preview.shouldWriteEngine) {
        ctrl.setParams(preview.engineParams!);
      }
    }
    final commit = adapter.adoptSourceWorld(
      objectId: kSpatialPointSourceIdV1,
      world: const Vec3V1(0.8, 0, -1.2),
      basedOnRevision: 1,
      commit: true,
    );
    expect(commit.sceneMutated, isTrue);
    expect(adapter.appliedRevision, 2);
    expect(ctrl.spatialSetParamsCalls, greaterThan(writesBefore));
    ctrl.dispose();
  });

  test('Array remains isolated from Point preview and commit', () {
    final ctrl = EngineController(engine: MockEngine());
    final array = ctrl.array.copy()..applyStereo2Preset();
    ctrl.setArray(array);
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    expect(ctrl.array.enabled, isTrue);
    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(ctrl.array.speakers, hasLength(2));
    expect(ctrl.array.speakers.first.azimuthDeg, closeTo(-30, trig));
    expect(ctrl.array.speakers.last.azimuthDeg, closeTo(30, trig));
    expect(bridge.adapter.config.emitterBindings, isEmpty);
    ctrl.dispose();
  });

  test('disposed bridge ignores late preview and commit', () {
    final bridge = boot();
    bridge.dispose();
    final preview = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    final commit = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(preview.shouldWriteEngine, isFalse);
    expect(commit.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
  });

  test('scene.js preview/commit keep object identity and reuse line geometry',
      () async {
    final js = await File('assets/spatial_workspace/scene.js').readAsString();
    expect(js.contains('objectsById'), isTrue);
    expect(js.contains('gestureBasedOnRevision'), isTrue);
    expect(js.contains('setLinePositions'), isTrue);
    expect(js.contains('dragSourceHold'), isTrue);
    expect(js.contains('relationLine.geometry.dispose()'), isFalse);
    expect(js.contains('applyPlaybackTelemetry'), isTrue);
    expect(js.contains('yinwei_set_params'), isFalse);
  });

  testWidgets('playhead ticks keep inspector mounted without workspace playhead churn',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine(), backendLabel: 'Mock');
    ctrl.hasOpenedFile = true; // This test models a loaded, paused track.
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(
          controller: ctrl,
          capabilities: _testDesktopCaps,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.byType(PositionSidebar), findsOneWidget);
    expect(find.byType(NowPlayingPanel), findsOneWidget);
    final workspace = tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace));
    final playheadBefore = workspace.playhead;
    expect(playheadBefore, greaterThan(0.2));
    expect(find.text('01:42'), findsWidgets);

    ctrl.position = Duration.zero;
    ctrl.notifyListeners();
    await tester.pump();

    final workspaceAfter =
        tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace));
    expect(workspaceAfter.playhead, playheadBefore);
    expect(find.byType(PositionSidebar), findsOneWidget);
    expect(find.text('00:00'), findsWidgets);
  });
}
