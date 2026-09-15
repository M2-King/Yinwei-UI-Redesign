import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';

Vec3V1 _sourceWorld(Map<String, dynamic> scene, [String id = kSpatialPointSourceIdV1]) {
  final source = (scene['sources'] as List).cast<Map>().firstWhere(
        (s) => s['id'] == id,
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
  required String objectId,
  required double x,
  required double y,
  required double z,
  required int basedOnRevision,
  int? newRevision,
}) {
  return {
    'type': type,
    'objectId': objectId,
    'worldPosition': {'x': x, 'y': y, 'z': z},
    'basedOnRevision': basedOnRevision,
    if (newRevision != null) 'newRevision': newRevision,
  };
}

void main() {
  const trig = 1e-6;

  SpatialSceneBridge boot([SpatialRuntimeAdapter? adapter]) {
    final a = adapter ?? SpatialRuntimeAdapter();
    a.bootstrap(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5),
    );
    return SpatialSceneBridge(adapter: a);
  }

  test('3 ready event causes latest scene snapshot to be sent', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode({'type': 'ready'}));
    expect(result.outgoing, isNotEmpty);
    expect(result.outgoing.first['type'], 'sceneSnapshot');
    expect(result.outgoing.first['revision'], 1);
    expect(result.shouldWriteEngine, isFalse);
  });

  test('4 scene snapshot contains schemaVersion/revision/stable IDs', () {
    final bridge = boot();
    final snap = bridge.handleMessage(jsonEncode({'type': 'ready'})).outgoing.first;
    expect(snap['schemaVersion'], 1);
    expect(snap['revision'], 1);
    final scene = snap['scene'] as Map;
    expect(scene['schemaVersion'], 1);
    expect(scene['revision'], 1);
    expect(scene['listener']['id'], kSpatialListenerIdV1);
    expect((scene['sources'] as List).first['id'], kSpatialPointSourceIdV1);
    expect(scene.containsKey('camera'), isFalse);
    expect(scene.containsKey('selection'), isFalse);
    expect(scene.containsKey('playhead'), isFalse);
  });

  test('5 JS never supplies authoritative revision', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
      newRevision: 99,
    )));
    expect(result.accepted, isTrue);
    expect(bridge.adapter.appliedRevision, 2);
    expect(bridge.adapter.appliedRevision, isNot(99));
    expect(result.outgoing.first['revision'], 2);
  });

  test('6 Flutter increments revision', () {
    final bridge = boot();
    expect(bridge.adapter.appliedRevision, 1);
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(bridge.adapter.appliedRevision, 2);
  });

  test('7 current-revision intent accepted', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -2,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(result.sceneMutated, isTrue);
    expect(result.shouldWriteEngine, isTrue);
  });

  test('8 stale-revision intent rejected', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 0,
    )));
    expect(result.accepted, isFalse);
    expect(result.reason, 'stale_revision');
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
  });

  test('9 stale rejection returns latest authoritative snapshot', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 2,
      y: 0,
      z: 0,
      basedOnRevision: 7,
    )));
    expect(result.outgoing, isNotEmpty);
    expect(result.outgoing.first['type'], 'sceneSnapshot');
    expect(result.outgoing.first['revision'], 1);
    final world = _sourceWorld(result.outgoing.first['scene'] as Map<String, dynamic>);
    expect(world.x, closeTo(1.5, trig));
  });

  test('10 world XYZ intent maps directly into Scene V1', () {
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0.4,
      y: 0.2,
      z: -1.1,
      basedOnRevision: 1,
    )));
    final world = _sourceWorld(bridge.adapter.snapshot()!);
    expect(world.x, closeTo(0.4, trig));
    expect(world.y, closeTo(0.2, trig));
    expect(world.z, closeTo(-1.1, trig));
  });

  test('11 +X = right', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(result.engineParams!.azimuthDeg, closeTo(90, trig));
  });

  test('12 +Y = up', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 1,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(result.engineParams!.elevationDeg, closeTo(90, trig));
  });

  test('13 -Z = front', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    expect(result.engineParams!.azimuthDeg, closeTo(0, trig));
    expect(result.engineParams!.elevationDeg, closeTo(0, trig));
  });

  test('14 source ID remains stable', () {
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -2,
      basedOnRevision: 1,
    )));
    expect(
      (bridge.adapter.snapshot()!['sources'] as List).first['id'],
      kSpatialPointSourceIdV1,
    );
  });

  test('15 accepted commit produces one logical Point engine update', () {
    final writes = <SpatialParams>[];
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    if (result.shouldWriteEngine) writes.add(result.engineParams!);
    expect(writes, hasLength(1));
  });

  test('16 rejected intent produces zero engine writes', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 0,
    )));
    expect(result.shouldWriteEngine, isFalse);
  });

  test('17 unknown source produces zero engine writes', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: 'speakers[0]',
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isFalse);
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
    expect(result.outgoing.first['type'], 'sceneSnapshot');
  });

  test('18 camera movement produces zero engine writes', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    final result = bridge.handleMessage(jsonEncode({
      'type': 'cameraMoved',
      'theta': 0.4,
      'phi': 1.1,
      'radius': 5,
    }));
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, rev);
    expect(
      result.outgoing.any((m) => m['type'] == 'sceneSnapshot'),
      isFalse,
    );
  });

  test('19 selection produces zero engine writes', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    final result = bridge.handleMessage(jsonEncode({
      'type': 'selectObject',
      'objectId': kSpatialPointSourceIdV1,
    }));
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, rev);
    expect(result.selectedObjectId, kSpatialPointSourceIdV1);
    expect(bridge.selectedObjectId, kSpatialPointSourceIdV1);
    final scene = bridge.adapter.snapshot()!;
    expect(scene.containsKey('selection'), isFalse);
    expect(
      result.outgoing.any((m) => m['type'] == 'uiState'),
      isTrue,
    );
  });

  test('Phase 3 listener and emitter selection do not mutate scene', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    final listener = bridge.handleMessage(jsonEncode({
      'type': 'selectObject',
      'objectId': kSpatialListenerIdV1,
    }));
    expect(listener.shouldWriteEngine, isFalse);
    expect(listener.sceneMutated, isFalse);
    expect(bridge.adapter.appliedRevision, rev);
    expect(bridge.selectedObjectId, kSpatialListenerIdV1);
    final emitters = bridge.adapter.snapshot()!['emitters'] as List;
    final emitterId = (emitters.first as Map)['id'] as String;
    final emitter = bridge.handleMessage(jsonEncode({
      'type': 'selectObject',
      'objectId': emitterId,
    }));
    expect(emitter.shouldWriteEngine, isFalse);
    expect(emitter.sceneMutated, isFalse);
    expect(bridge.adapter.appliedRevision, rev);
    expect(bridge.selectedObjectId, emitterId);
  });

  test('20 playback telemetry produces zero engine writes', () {
    final bridge = boot();
    final rev = bridge.adapter.appliedRevision;
    bridge.observePlaybackTelemetry(playhead: 0.52, playing: true);
    expect(bridge.adapter.appliedRevision, rev);
    final jsTelemetry = bridge.handleMessage(jsonEncode({
      'type': 'playbackTelemetry',
      'playhead': 0.8,
      'playing': true,
    }));
    expect(jsTelemetry.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, rev);
    final outgoing = bridge.playbackTelemetryMessage();
    expect(outgoing['type'], 'playbackTelemetry');
    expect(outgoing['playhead'], 0.52);
    expect(outgoing.containsKey('speakers'), isFalse);
    expect(outgoing.containsKey('scene'), isFalse);
  });

  test('21 scene snapshot updates existing object by ID', () {
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
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
      ],
    });
    expect(registry.createCount('source-main'), 1);
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
    expect(registry.createCount('source-main'), 1);
    expect(registry.positionOf('source-main')!['z'], -2);
  });

  test('22 unchanged object is not unnecessarily recreated', () {
    final registry = SpatialRendererRegistry();
    final scene = {
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
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
        {
          'id': 'emitter-FR',
          'worldPosition': {'x': 1, 'y': 0, 'z': -1},
        },
      ],
    };
    registry.applySceneSnapshot(scene);
    registry.applySceneSnapshot(scene);
    expect(registry.createCount('emitter-FL'), 1);
    expect(registry.createCount('emitter-FR'), 1);
    expect(registry.createCount('listener-0'), 1);
  });

  test('23 playback update does not rebuild speaker objects', () {
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
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
      ],
    });
    registry.applyPlaybackTelemetry({'playhead': 0.1, 'playing': true});
    registry.applyPlaybackTelemetry({'playhead': 0.2, 'playing': true});
    expect(registry.createCount('emitter-FL'), 1);
    expect(registry.rebuildSpeakers, 0);
  });

  test('24 removed object gets removed', () {
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
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
        {
          'id': 'emitter-FR',
          'worldPosition': {'x': 1, 'y': 0, 'z': -1},
        },
      ],
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
          'id': 'emitter-FL',
          'worldPosition': {'x': -1, 'y': 0, 'z': -1},
        },
      ],
    });
    expect(registry.contains('emitter-FR'), isFalse);
    expect(registry.contains('emitter-FL'), isTrue);
  });

  test('25 new object gets created', () {
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
      'emitters': [],
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
          'id': 'emitter-C',
          'worldPosition': {'x': 0, 'y': 0, 'z': -2},
        },
      ],
    });
    expect(registry.createCount('emitter-C'), 1);
    expect(registry.contains('emitter-C'), isTrue);
  });

  test('26 malformed JS message is ignored safely', () {
    final bridge = boot();
    expect(
      () => bridge.handleMessage('{not-json'),
      returnsNormally,
    );
    final result = bridge.handleMessage('{not-json');
    expect(result.accepted, isFalse);
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
  });

  test('27 WebView ready after reload receives latest scene', () {
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0.5,
      z: -1,
      basedOnRevision: 1,
    )));
    expect(bridge.adapter.appliedRevision, 2);
    final reload = bridge.handleMessage(jsonEncode({'type': 'ready'}));
    expect(reload.outgoing.first['revision'], 2);
    final world = _sourceWorld(reload.outgoing.first['scene'] as Map<String, dynamic>);
    expect(world.y, closeTo(0.5, trig));
  });

  test('28 unknown message type does not crash', () {
    final bridge = boot();
    expect(
      () => bridge.handleMessage(jsonEncode({'type': 'explodeScene'})),
      returnsNormally,
    );
    final result = bridge.handleMessage(jsonEncode({'type': 'explodeScene'}));
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
  });

  test('29 bridge dispose produces no late update crash', () {
    final bridge = boot();
    bridge.dispose();
    expect(
      () => bridge.handleMessage(jsonEncode({'type': 'ready'})),
      returnsNormally,
    );
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(result.shouldWriteEngine, isFalse);
    expect(result.outgoing, isEmpty);
    expect(bridge.adapter.appliedRevision, 1);
  });

  test('30 source drag preview reaches Flutter', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      objectId: kSpatialPointSourceIdV1,
      x: 0.2,
      y: 0.1,
      z: -1.4,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(result.shouldWriteEngine, isTrue);
    final world = _sourceWorld(bridge.adapter.snapshot()!);
    expect(world.x, closeTo(0.2, trig));
  });

  test('31 source drag commit reaches Flutter', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0.7,
      y: 0.0,
      z: -1.2,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(result.outgoing.first['type'], 'sceneSnapshot');
  });

  test('32 commit generates authoritative revision', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -2,
      basedOnRevision: 1,
    )));
    expect(bridge.adapter.appliedRevision, 2);
    expect(result.outgoing.first['revision'], 2);
  });

  test('33 returned scene matches accepted position', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 1.25,
      y: 0.3,
      z: -0.8,
      basedOnRevision: 1,
    )));
    final world = _sourceWorld(result.outgoing.first['scene'] as Map<String, dynamic>);
    expect(world.x, closeTo(1.25, trig));
    expect(world.y, closeTo(0.3, trig));
    expect(world.z, closeTo(-0.8, trig));
  });

  test('34 Array legacy path remains independent', () {
    final ctrl = EngineController();
    final bridge = boot();
    final array = ctrl.array.copy()..applyStereo2Preset();
    ctrl.setArray(array);
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    expect(ctrl.array.enabled, isTrue);
    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(ctrl.array.speakers, hasLength(2));
    ctrl.dispose();
  });

  test('35 visual emitter order/role does not alter acoustic Array routing', () {
    final ctrl = EngineController();
    final bridge = boot();
    final array = ctrl.array.copy()..applyStereo2Preset();
    ctrl.setArray(array);
    final emitters = bridge.adapter.snapshot()!['emitters'] as List;
    expect(emitters.first['id'], isNot(array.speakers.first.label));
    expect(bridge.adapter.config.emitterBindings, isEmpty);
    expect(ctrl.array.speakers.map((s) => s.label).toList(), ['L', 'R']);
    ctrl.dispose();
  });

  test('preview of unchanged pose does not churn revision', () {
    final bridge = boot();
    final first = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 1,
    )));
    expect(first.accepted, isTrue);
    expect(bridge.adapter.appliedRevision, 2);
    final second = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePosePreview',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -1,
      basedOnRevision: 2,
    )));
    expect(second.accepted, isTrue);
    expect(second.sceneMutated, isFalse);
    expect(bridge.adapter.appliedRevision, 2);
  });

  test('invalid coordinates reject without engine write', () {
    final bridge = boot();
    final result = bridge.handleMessage(
      '{"type":"sourcePoseCommit","objectId":"source-main",'
      '"worldPosition":{"x":null,"y":0,"z":-1},"basedOnRevision":1}',
    );
    expect(result.accepted, isFalse);
    expect(result.shouldWriteEngine, isFalse);
    expect(bridge.adapter.appliedRevision, 1);
    expect(result.outgoing.first['type'], 'sceneSnapshot');
  });

  test('domain quaternion stays (w,x,y,z) and Three.js conversion is boundary-only', () {
    const domain = {'w': 1.0, 'x': 0.0, 'y': 0.0, 'z': 0.0};
    final three = domainQuatToThreeJs(domain);
    expect(three.keys.toList(), ['x', 'y', 'z', 'w']);
    expect(three['w'], 1.0);
    final roundTrip = threeJsQuatToDomain(three);
    expect(roundTrip.keys.toList(), ['w', 'x', 'y', 'z']);
    expect(boot().adapter.snapshot()!['listener']['orientation']['w'], 1);
  });

  test('Three.js scene.js uses intent protocol and object registry', () async {
    final js = await File('assets/spatial_workspace/scene.js').readAsString();
    expect(js.contains('sourcePosePreview'), isTrue);
    expect(js.contains('sourcePoseCommit'), isTrue);
    expect(js.contains('basedOnRevision'), isTrue);
    expect(js.contains('newRevision'), isFalse);
    expect(js.contains('applySceneSnapshot'), isTrue);
    expect(js.contains('applyPlaybackTelemetry'), isTrue);
    expect(js.contains('objectsById'), isTrue);
    expect(js.contains('yinwei_set_params'), isFalse);
    expect(js.contains('EngineApi'), isFalse);
    expect(RegExp(r'applyPlaybackTelemetry[\s\S]*rebuildSpeakers').hasMatch(js), isFalse);
  });

  test('stale rejection does not rewind Flutter scene state', () {
    final bridge = boot();
    bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -2,
      basedOnRevision: 1,
    )));
    expect(bridge.adapter.appliedRevision, 2);
    final stale = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 3,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(stale.accepted, isFalse);
    expect(bridge.adapter.appliedRevision, 2);
    expect(_sourceWorld(bridge.adapter.snapshot()!).z, closeTo(-2, trig));
    expect(stale.applyStatus, SceneApplyStatusV1.rejectedStale);
  });

  test('Phase 3 elevation world Y updates Scene and engine elevation', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0.8,
      z: -2,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(bridge.adapter.appliedRevision, 2);
    expect(_sourceWorld(bridge.adapter.snapshot()!).y, closeTo(0.8, trig));
    expect(result.engineParams!.elevationDeg, greaterThan(10));
    expect(result.engineParams!.azimuthDeg, closeTo(0, 1e-3));
  });

  test('Phase 3 geometric 25m stays unclamped while DSP projects to 10', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: -25,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    final world = _sourceWorld(bridge.adapter.snapshot()!);
    expect(world.z, closeTo(-25, trig));
    expect(world.length, closeTo(25, trig));
    expect(result.engineParams!.distanceM, 10);
  });

  test('Phase 3 zero-distance world remains projection-safe', () {
    final bridge = boot();
    final result = bridge.handleMessage(jsonEncode(_poseIntent(
      type: 'sourcePoseCommit',
      objectId: kSpatialPointSourceIdV1,
      x: 0,
      y: 0,
      z: 0,
      basedOnRevision: 1,
    )));
    expect(result.accepted, isTrue);
    expect(_sourceWorld(bridge.adapter.snapshot()!).length, closeTo(0, trig));
    expect(result.engineParams!.distanceM, greaterThanOrEqualTo(0.5));
  });
}
