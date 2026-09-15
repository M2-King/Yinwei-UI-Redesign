import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/audio_projection_v1.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/engine_controller.dart';

Vec3V1 _sourceWorld(Map<String, dynamic> scene) {
  final sources = scene['sources'] as List;
  final source = sources.cast<Map>().firstWhere(
        (s) => s['id'] == kSpatialPointSourceIdV1,
      );
  final p = source['worldPosition'] as Map;
  return Vec3V1(
    (p['x'] as num).toDouble(),
    (p['y'] as num).toDouble(),
    (p['z'] as num).toDouble(),
  );
}

double _geometric(Map<String, dynamic> scene) =>
    geometricDistanceM(_sourceWorld(scene));

SpatialAdoptionResult _write(
  SpatialRuntimeAdapter adapter,
  SpatialParams next,
  List<SpatialParams> writes,
) {
  final result = adapter.adoptPointParams(next);
  if (result.shouldWriteEngine) {
    writes.add(result.engineParams!.copy());
  }
  return result;
}

void main() {
  const trig = 1e-6;

  test('1 existing runtime pose converts into correct Scene V1 XYZ', () {
    final adapter = SpatialRuntimeAdapter();
    final params = SpatialParams(
      azimuthDeg: 90,
      elevationDeg: 0,
      distanceM: 1.5,
    );
    adapter.bootstrap(params);
    final world = sphericalToLocal(const SphericalV1(
      azimuthDeg: 90,
      elevationDeg: 0,
      distanceM: 1.5,
    ));
    final got = _sourceWorld(adapter.snapshot()!);
    expect(got.x, closeTo(world.x, trig));
    expect(got.y, closeTo(world.y, trig));
    expect(got.z, closeTo(world.z, trig));
  });

  test('2 bootstrap scene accepted', () {
    final adapter = SpatialRuntimeAdapter();
    final result = adapter.bootstrap(SpatialParams());
    expect(result.status, SceneApplyStatusV1.applied);
    expect(adapter.hasScene, isTrue);
    expect(adapter.appliedRevision, 1);
  });

  test('3 stable listener/source IDs preserved', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final scene = adapter.snapshot()!;
    expect(scene['listener']['id'], kSpatialListenerIdV1);
    expect(
      (scene['sources'] as List).first['id'],
      kSpatialPointSourceIdV1,
    );
    adapter.adoptPointParams(SpatialParams(azimuthDeg: 0, distanceM: 2));
    final next = adapter.snapshot()!;
    expect(next['listener']['id'], kSpatialListenerIdV1);
    expect(
      (next['sources'] as List).first['id'],
      kSpatialPointSourceIdV1,
    );
  });

  test('4 audio config explicitly binds source ID', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    expect(adapter.config.pointSourceId, kSpatialPointSourceIdV1);
    expect(adapter.config.emitterBindings, isEmpty);
  });

  test('5 UI azimuth change creates revision +1', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    expect(adapter.appliedRevision, 1);
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: -10, distanceM: 1.8),
    );
    expect(result.sceneAccepted, isTrue);
    expect(result.sceneMutated, isTrue);
    expect(adapter.appliedRevision, 2);
  });

  test('6 elevation update creates revision +1 and correct XYZ', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    expect(adapter.appliedRevision, 1);
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 90, distanceM: 1),
    );
    expect(result.sceneMutated, isTrue);
    expect(adapter.appliedRevision, 2);
    final world = sphericalToLocal(const SphericalV1(
      azimuthDeg: 0,
      elevationDeg: 90,
      distanceM: 1,
    ));
    final got = _sourceWorld(adapter.snapshot()!);
    expect(got.x, closeTo(world.x, trig));
    expect(got.y, closeTo(world.y, trig));
    expect(got.z, closeTo(world.z, trig));
  });

  test('7 distance update creates revision +1 and preserves geometric distance', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    expect(adapter.appliedRevision, 1);
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 4),
    );
    expect(result.sceneMutated, isTrue);
    expect(adapter.appliedRevision, 2);
    expect(_geometric(adapter.snapshot()!), closeTo(4, trig));
  });

  test('8 next snapshot replaces previous scene cleanly', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 2),
    );
    final firstZ = _sourceWorld(adapter.snapshot()!).z;
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 2),
    );
    final second = _sourceWorld(adapter.snapshot()!);
    expect(firstZ, closeTo(-2, trig));
    expect(second.x, closeTo(2, trig));
    expect(adapter.appliedRevision, 3);
  });

  test('9 stale scene never reaches engine adapter', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final writes = <SpatialParams>[];
    final stale = Map<String, dynamic>.from(adapter.snapshot()!);
    stale['revision'] = 1;
    final result = adapter.tryApplyScene(stale);
    expect(result.sceneAccepted, isFalse);
    expect(result.applyStatus, SceneApplyStatusV1.rejectedStale);
    expect(result.shouldWriteEngine, isFalse);
    if (result.shouldWriteEngine) {
      writes.add(result.engineParams!);
    }
    expect(writes, isEmpty);
    expect(adapter.appliedRevision, 1);
  });

  test('10 front source projects correctly', () {
    final writes = <SpatialParams>[];
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    _write(
      adapter,
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 1),
      writes,
    );
    expect(writes, hasLength(1));
    expect(writes.single.azimuthDeg, closeTo(0, trig));
    expect(writes.single.elevationDeg, closeTo(0, trig));
    expect(writes.single.distanceM, closeTo(1, trig));
  });

  test('11 right/left/rear project correctly', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final right = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1),
    );
    expect(right.engineParams!.azimuthDeg, closeTo(90, trig));
    final left = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: -90, elevationDeg: 0, distanceM: 1),
    );
    expect(left.engineParams!.azimuthDeg, closeTo(-90, trig));
    final rear = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 180, elevationDeg: 0, distanceM: 1),
    );
    expect(rear.engineParams!.azimuthDeg.abs(), closeTo(180, trig));
  });

  test('12 zero distance stays geometric 0 and DSP 0.5', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 0),
    );
    expect(_geometric(adapter.snapshot()!), 0);
    expect(result.engineParams!.distanceM, kDspDistanceMinM);
    expect(result.pointSourceStatus, PointSourceStatusV1.projected);
  });

  test('13 >10m stays geometric >10 and DSP projects to 10', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 25),
    );
    expect(_geometric(adapter.snapshot()!), closeTo(25, 1e-9));
    expect(result.engineParams!.distanceM, kDspDistanceMaxM);
  });

  test('14 listener identity behavior matches current runtime', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final q = adapter.snapshot()!['listener']['orientation'] as Map;
    expect(q['w'], 1);
    expect(q['x'], 0);
    expect(q['y'], 0);
    expect(q['z'], 0);
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 45, elevationDeg: 0, distanceM: 1.5),
    );
    expect(result.engineParams!.azimuthDeg, closeTo(45, 1e-4));
  });

  test('15 missing configured source does not fall back', () {
    final adapter = SpatialRuntimeAdapter(pointSourceId: 'no-such-source')
      ..bootstrap(SpatialParams());
    final writes = <SpatialParams>[];
    final result = _write(
      adapter,
      SpatialParams(azimuthDeg: 0, distanceM: 1),
      writes,
    );
    expect(result.pointSourceStatus, PointSourceStatusV1.sourceMissing);
    expect(result.shouldWriteEngine, isFalse);
    expect(writes, isEmpty);
    expect(
      (adapter.snapshot()!['sources'] as List).first['id'],
      kSpatialPointSourceIdV1,
    );
  });

  test('16 wrong source ID produces no engine write', () {
    final adapter = SpatialRuntimeAdapter(pointSourceId: 'source-other')
      ..bootstrap(SpatialParams());
    expect(adapter.adoptPointParams(SpatialParams()).shouldWriteEngine, isFalse);
  });

  test('17 visual emitter role cannot affect Point routing', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    expect(adapter.config.emitterBindings, isEmpty);
    final emitters = adapter.snapshot()!['emitters'] as List;
    expect(emitters, isNotEmpty);
    expect(
      emitters.cast<Map>().any((e) => e['visualRole'] == 'C'),
      isTrue,
    );
    final result = adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5),
    );
    expect(result.engineParams!.azimuthDeg, closeTo(90, 1e-4));
    expect(result.projection!.emitterSlots, isEmpty);
  });

  test('18 one accepted scene mutation results in exactly one logical spatial engine update',
      () {
    final writes = <SpatialParams>[];
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    _write(
      adapter,
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 1.5),
      writes,
    );
    expect(writes, hasLength(1));
  });

  test('19 rejected scene results in zero engine writes', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final invalid = Map<String, dynamic>.from(adapter.snapshot()!);
    invalid['revision'] = 2;
    invalid['camera'] = {'distance': 5};
    final result = adapter.tryApplyScene(invalid);
    expect(result.applyStatus, SceneApplyStatusV1.rejectedInvalid);
    expect(result.shouldWriteEngine, isFalse);
  });

  test('20 telemetry does not recursively create scene revisions', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 30, elevationDeg: 0, distanceM: 1.8),
    );
    final rev = adapter.appliedRevision;
    adapter.observePlaybackTelemetry(azimuthDeg: 88, elevationDeg: 12);
    expect(adapter.appliedRevision, rev);
    expect(
      adapter.adoptPointParams(
        SpatialParams(azimuthDeg: 30, elevationDeg: 0, distanceM: 1.8),
      ).sceneMutated,
      isFalse,
    );
  });

  test('21 rapid UI updates preserve latest authoritative scene', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 1),
    );
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 10, elevationDeg: 0, distanceM: 1),
    );
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1),
    );
    expect(adapter.appliedRevision, 4);
    expect(
      adapter.adoptPointParams(
        SpatialParams(azimuthDeg: 90, elevationDeg: 0, distanceM: 1),
      ).engineParams!.azimuthDeg,
      closeTo(90, trig),
    );
    final world = _sourceWorld(adapter.snapshot()!);
    expect(world.x, closeTo(1, trig));
  });

  test('22 existing Point-mode UI callback still updates spatial state', () {
    final ctrl = EngineController();
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    void applySpatialFromUi(SpatialParams next) {
      final adopted = adapter.adoptPointParams(next);
      if (!adopted.shouldWriteEngine) return;
      ctrl.setParams(adopted.engineParams!);
    }

    applySpatialFromUi(
      ctrl.params.copy()
        ..azimuthDeg = 0
        ..elevationDeg = 0
        ..distanceM = 2
        ..selectedPreset = null,
    );
    expect(ctrl.params.azimuthDeg, closeTo(0, trig));
    expect(ctrl.params.distanceM, closeTo(2, trig));
    ctrl.dispose();
  });

  test('23 current playback controls remain unaffected at unit level', () {
    final ctrl = EngineController();
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    expect(ctrl.playing, isFalse);
    expect(ctrl.mode, PlaybackMode.spatial);
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 45, elevationDeg: 0, distanceM: 1.5),
    );
    expect(ctrl.playing, isFalse);
    expect(ctrl.mode, PlaybackMode.spatial);
    expect(ctrl.track.title, isNotEmpty);
    ctrl.dispose();
  });

  test('24 Array mode legacy path is not accidentally rerouted', () {
    final ctrl = EngineController();
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    final array = ctrl.array.copy()..applyStereo2Preset();
    ctrl.setArray(array);
    adapter.adoptPointParams(
      SpatialParams(azimuthDeg: 0, elevationDeg: 0, distanceM: 1),
    );
    expect(ctrl.array.enabled, isTrue);
    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(ctrl.array.speakers, hasLength(2));
    ctrl.dispose();
  });

  test('25 scene adoption does not require Three.js availability', () {
    final adapter = SpatialRuntimeAdapter();
    expect(adapter.bootstrap(SpatialParams()).accepted, isTrue);
    expect(
      adapter
          .adoptPointParams(
            SpatialParams(azimuthDeg: -45, elevationDeg: 0, distanceM: 1.5),
          )
          .shouldWriteEngine,
      isTrue,
    );
  });
}
