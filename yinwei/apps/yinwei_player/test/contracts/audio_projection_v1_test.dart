import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/audio_projection_v1.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/speaker_semantics_v1.dart';

import 'fixture_loader.dart';

Map<String, dynamic> _object({
  required String id,
  required String type,
  double x = 0,
  double y = 0,
  double z = 0,
  bool enabled = true,
  bool active = true,
  Map<String, double>? orientation,
  String? visualRole,
}) {
  return {
    'id': id,
    'type': type,
    'worldPosition': {'x': x, 'y': y, 'z': z},
    if (orientation != null)
      'orientation': {
        'w': orientation['w'] ?? 1,
        'x': orientation['x'] ?? 0,
        'y': orientation['y'] ?? 0,
        'z': orientation['z'] ?? 0,
      },
    'enabled': enabled,
    'active': active,
    if (visualRole != null) 'visualRole': visualRole,
  };
}

Map<String, dynamic> _scene({
  int revision = 1,
  Map<String, dynamic>? listener,
  List<Map<String, dynamic>>? sources,
  List<Map<String, dynamic>>? emitters,
}) {
  return {
    'schemaVersion': 1,
    'revision': revision,
    'listener': listener ??
        _object(
          id: 'listener-0',
          type: 'listener',
          orientation: {'w': 1, 'x': 0, 'y': 0, 'z': 0},
        ),
    'sources': sources ??
        [
          _object(id: 'source-0', type: 'source', z: -1),
        ],
    'emitters': emitters ?? const <Map<String, dynamic>>[],
  };
}

AudioProjectionResultV1 _project(
  Map<String, dynamic> scene, {
  String sourceId = 'source-0',
  Map<String, String> emitters = const {},
}) {
  return AudioProjectionV1.project(
    scene: scene,
    config: AudioProjectionConfigV1(
      pointSourceId: sourceId,
      emitterBindings: emitters,
    ),
  );
}

void _expectVec(Vec3V1 got, Map expectMap, double eps) {
  expect(got.x, closeTo(asF(expectMap['x']), eps));
  expect(got.y, closeTo(asF(expectMap['y']), eps));
  expect(got.z, closeTo(asF(expectMap['z']), eps));
}

void main() {
  final coord = loadContractFixture('coordinate_fixtures_v1.json');
  final trig = asF(coord['trigTolerance']);
  final tight = asF(coord['tolerance']);

  Map<String, dynamic> caseById(String id) {
    return (coord['cases'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['id'] == id);
  }

  test('10 identity listener + source in front', () {
    final c = caseById('front');
    final world = c['expect']['world'] as Map<String, dynamic>;
    final result = _project(_scene(sources: [
      _object(
        id: 'source-0',
        type: 'source',
        x: asF(world['x']),
        y: asF(world['y']),
        z: asF(world['z']),
      ),
    ]));
    expect(result.isSuccess, isTrue);
    expect(result.pointSource!.azimuthDeg, closeTo(0, trig));
    expect(result.pointSource!.elevationDeg, closeTo(0, trig));
    expect(result.pointSource!.geometricDistanceM, closeTo(1, tight));
    _expectVec(result.pointSource!.hrtfUnit, c['expect']['hrtfUnit'] as Map<String, dynamic>, tight);
  });

  test('11 listener translation from Phase 1A fixture', () {
    final c = caseById('translated_listener');
    final listener = c['listener'] as Map<String, dynamic>;
    final world = c['world'] as Map<String, dynamic>;
    final expectMap = c['expect'] as Map<String, dynamic>;
    final result = _project(_scene(
      listener: _object(
        id: 'listener-0',
        type: 'listener',
        x: asF(listener['worldPosition']['x']),
        y: asF(listener['worldPosition']['y']),
        z: asF(listener['worldPosition']['z']),
        orientation: {
          'w': asF(listener['orientation']['w']),
          'x': asF(listener['orientation']['x']),
          'y': asF(listener['orientation']['y']),
          'z': asF(listener['orientation']['z']),
        },
      ),
      sources: [
        _object(
          id: 'source-0',
          type: 'source',
          x: asF(world['x']),
          y: asF(world['y']),
          z: asF(world['z']),
        ),
      ],
    ));
    expect(result.isSuccess, isTrue);
    _expectVec(result.pointSource!.listenerLocal, expectMap['listenerLocal'] as Map<String, dynamic>, trig);
    expect(result.pointSource!.azimuthDeg, closeTo(asF(expectMap['azimuthDeg']), trig));
    expect(result.pointSource!.geometricDistanceM, closeTo(asF(expectMap['distanceM']), trig));
  });

  test('12 and 37 listener rotation matches Phase 1A fixture', () {
    final c = caseById('rotated_listener');
    final listener = c['listener'] as Map<String, dynamic>;
    final world = c['world'] as Map<String, dynamic>;
    final expectMap = c['expect'] as Map<String, dynamic>;
    final result = _project(_scene(
      listener: _object(
        id: 'listener-0',
        type: 'listener',
        orientation: {
          'w': asF(listener['orientation']['w']),
          'x': asF(listener['orientation']['x']),
          'y': asF(listener['orientation']['y']),
          'z': asF(listener['orientation']['z']),
        },
      ),
      sources: [
        _object(
          id: 'source-0',
          type: 'source',
          x: asF(world['x']),
          y: asF(world['y']),
          z: asF(world['z']),
        ),
      ],
    ));
    expect(result.isSuccess, isTrue);
    _expectVec(result.pointSource!.listenerLocal, expectMap['listenerLocal'] as Map<String, dynamic>, trig);
    expect(result.pointSource!.azimuthDeg, closeTo(0, trig));
    expect(result.pointSource!.geometricDistanceM, closeTo(2, trig));
  });

  test('13 source right', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', x: 1),
    ]));
    expect(result.pointSource!.azimuthDeg, closeTo(90, trig));
    expect(result.pointSource!.hrtfUnit.x, closeTo(1, tight));
  });

  test('14 source left', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', x: -1),
    ]));
    expect(result.pointSource!.azimuthDeg, closeTo(-90, trig));
  });

  test('15 source behind', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: 1),
    ]));
    expect(result.pointSource!.azimuthDeg, closeTo(180, trig));
  });

  test('16 elevation', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', y: 1),
    ]));
    expect(result.pointSource!.elevationDeg, closeTo(90, trig));
    expect(result.pointSource!.hrtfUnit.y, closeTo(1, tight));
  });

  test('17 quaternion normalization', () {
    final result = _project(_scene(
      listener: _object(
        id: 'listener-0',
        type: 'listener',
        orientation: {'w': 2, 'x': 0, 'y': 0, 'z': 0},
      ),
      sources: [_object(id: 'source-0', type: 'source', z: -1)],
    ));
    expect(result.isSuccess, isTrue);
    expect(result.pointSource!.azimuthDeg, closeTo(0, trig));
  });

  test('18 quaternion storage order remains (w,x,y,z)', () {
    expect(coord['quaternionStorageOrder'], ['w', 'x', 'y', 'z']);
    final result = _project(_scene());
    expect(result.pointSource!.quaternionStorageOrder, ['w', 'x', 'y', 'z']);
  });

  test('19-21 zero-distance forward fallback and DSP clamp', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source'),
    ]));
    expect(result.isSuccess, isTrue);
    expect(result.pointSource!.geometricDistanceM, 0);
    expect(result.pointSource!.hrtfUnit.x, closeTo(0, tight));
    expect(result.pointSource!.hrtfUnit.y, closeTo(0, tight));
    expect(result.pointSource!.hrtfUnit.z, closeTo(-1, tight));
    expect(result.pointSource!.dspDistanceM, kDspDistanceMinM);
  });

  test('22 DSP distance clamps maximum to 10', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: -25),
    ]));
    expect(result.pointSource!.geometricDistanceM, closeTo(25, trig));
    expect(result.pointSource!.dspDistanceM, kDspDistanceMaxM);
  });

  test('23 unclamped intermediate distance remains unchanged', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: -4),
    ]));
    expect(result.pointSource!.geometricDistanceM, closeTo(4, trig));
    expect(result.pointSource!.dspDistanceM, closeTo(4, trig));
  });

  test('21b geometric 0.2 still clamps DSP to 0.5', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: -0.2),
    ]));
    expect(result.pointSource!.geometricDistanceM, closeTo(0.2, trig));
    expect(result.pointSource!.dspDistanceM, kDspDistanceMinM);
  });

  test('24 explicitly bound source projected', () {
    final result = _project(
      _scene(sources: [
        _object(id: 'decoy', type: 'source', x: 9),
        _object(id: 'wanted', type: 'source', z: -1),
      ]),
      sourceId: 'wanted',
    );
    expect(result.pointSource!.sourceId, 'wanted');
    expect(result.pointSource!.azimuthDeg, closeTo(0, trig));
  });

  test('25 missing source ID returns defined failure', () {
    final result = _project(_scene(), sourceId: 'no-such-source');
    expect(result.isSuccess, isFalse);
    expect(result.pointSourceStatus, PointSourceStatusV1.sourceMissing);
    expect(result.pointSource, isNull);
  });

  test('26 no implicit sources.first fallback', () {
    final result = _project(
      _scene(sources: [
        _object(id: 'first', type: 'source', z: -1),
        _object(id: 'second', type: 'source', x: 1),
      ]),
      sourceId: 'missing',
    );
    expect(result.pointSourceStatus, PointSourceStatusV1.sourceMissing);
    expect(result.pointSource, isNull);
  });

  test('27 disabled source behavior', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: -1, enabled: false),
    ]));
    expect(result.pointSourceStatus, PointSourceStatusV1.sourceDisabled);
    expect(result.pointSource, isNull);
  });

  test('28 inactive source behavior', () {
    final result = _project(_scene(sources: [
      _object(id: 'source-0', type: 'source', z: -1, active: false),
    ]));
    expect(result.pointSourceStatus, PointSourceStatusV1.sourceInactive);
    expect(result.pointSource, isNull);
  });

  test('29 explicit emitter/feed binding only', () {
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-C', type: 'emitter', z: -2, visualRole: 'C'),
        _object(id: 'emitter-L', type: 'emitter', x: -1, z: -1.7, visualRole: 'L'),
      ]),
    );
    expect(result.emitterSlots, isEmpty);
  });

  test('30 visual Center does not imply center channel', () {
    expect(SpeakerSemanticsV1.isAcousticFeed('center'), isFalse);
    expect(SpeakerSemanticsV1.isAcousticFeed('C'), isFalse);
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-C', type: 'emitter', z: -2, visualRole: 'C'),
      ]),
      emitters: {'emitter-C': 'center'},
    );
    expect(result.emitterSlots.single.status, EmitterSlotStatusV1.failedInvalidFeed);
    expect(result.emitterSlots.single.feed, isNull);
  });

  test('31 visual LFE does not imply LFE routing', () {
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-LFE', type: 'emitter', y: -1, visualRole: 'LFE'),
      ]),
      emitters: {'emitter-LFE': 'lfe'},
    );
    expect(result.emitterSlots.single.status, EmitterSlotStatusV1.failedInvalidFeed);
  });

  test('32 array/list order does not define acoustic routing', () {
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-A', type: 'emitter', x: 1, visualRole: 'R'),
        _object(id: 'emitter-B', type: 'emitter', x: -1, visualRole: 'L'),
      ]),
      emitters: {
        'emitter-B': 'left',
        'emitter-A': 'right',
      },
    );
    expect(result.emitterSlots.map((s) => s.emitterId).toList(), ['emitter-A', 'emitter-B']);
    expect(result.emitterSlots[0].feed, AcousticFeedV1.right);
    expect(result.emitterSlots[1].feed, AcousticFeedV1.left);
  });

  test('32b emitterSlots are sorted by emitterId with feeds bound by id', () {
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-Z', type: 'emitter', x: 1),
        _object(id: 'emitter-A', type: 'emitter', x: -1),
        _object(id: 'emitter-M', type: 'emitter'),
      ]),
      emitters: {
        'emitter-Z': 'right',
        'emitter-A': 'left',
        'emitter-M': 'mid',
      },
    );
    expect(result.emitterSlots.map((s) => s.emitterId).toList(), [
      'emitter-A',
      'emitter-M',
      'emitter-Z',
    ]);
    expect(result.emitterSlots[0].feed, AcousticFeedV1.left);
    expect(result.emitterSlots[1].feed, AcousticFeedV1.mid);
    expect(result.emitterSlots[2].feed, AcousticFeedV1.right);
  });

  test('32c invalid scene with emitter bindings returns empty slots', () {
    final missingListener = _project(
      {
        'schemaVersion': 1,
        'revision': 1,
        'sources': [_object(id: 'source-0', type: 'source', z: -1)],
        'emitters': [_object(id: 'emitter-A', type: 'emitter')],
      },
      emitters: {'emitter-A': 'left'},
    );
    expect(missingListener.pointSourceStatus, PointSourceStatusV1.invalidScene);
    expect(missingListener.emitterSlots, isEmpty);
    expect(missingListener.reason, 'missing_listener');

    final forbidden = _project(
      {
        ..._scene(emitters: [_object(id: 'emitter-A', type: 'emitter')]),
        'camera': {'distance': 5},
      },
      emitters: {'emitter-A': 'left'},
    );
    expect(forbidden.pointSourceStatus, PointSourceStatusV1.invalidScene);
    expect(forbidden.emitterSlots, isEmpty);
    expect(forbidden.reason, 'forbidden_key');
  });

  test('33 invalid/unbound feed fails or is skipped per documented rules', () {
    final result = _project(
      _scene(emitters: [
        _object(id: 'emitter-L', type: 'emitter', x: -1, visualRole: 'L'),
        _object(id: 'emitter-ghost', type: 'emitter', x: 2),
      ]),
      emitters: {
        'emitter-missing': 'left',
        'emitter-L': 'rear',
      },
    );
    expect(result.emitterSlots.map((s) => s.emitterId).toList(), [
      'emitter-L',
      'emitter-missing',
    ]);
    expect(result.emitterSlots.map((s) => s.status).toList(), [
      EmitterSlotStatusV1.failedInvalidFeed,
      EmitterSlotStatusV1.failedUnknownEmitter,
    ]);
  });

  test('34 only Left / Right / Mid are valid current acoustic feeds', () {
    expect(SpeakerSemanticsV1.acousticFeeds, ['left', 'right', 'mid']);
    expect(parseAcousticFeedV1('left'), AcousticFeedV1.left);
    expect(parseAcousticFeedV1('RIGHT'), AcousticFeedV1.right);
    expect(parseAcousticFeedV1('Mid'), AcousticFeedV1.mid);
    expect(parseAcousticFeedV1('center'), isNull);
    expect(parseAcousticFeedV1('lfe'), isNull);
    expect(parseAcousticFeedV1('side'), isNull);
  });

  test('35 wrap around ±180° from Phase 1A fixtures', () {
    for (final id in ['wrap_plus_180', 'wrap_minus_180', 'wrap_plus_190', 'wrap_minus_190']) {
      final c = caseById(id);
      expect(wrapAzimuthDeg(asF(c['inputDeg'])), closeTo(asF(c['expectDeg']), tight));
    }
  });

  test('36 exact half-turn deterministic sign from Phase 1A fixtures', () {
    final pos = caseById('shortest_arc_half_turn_positive');
    final neg = caseById('shortest_arc_half_turn_negative');
    expect(
      shortestAzimuthDeltaDeg(asF(pos['fromDeg']), asF(pos['toDeg'])),
      closeTo(asF(pos['expectDeltaDeg']), tight),
    );
    expect(
      shortestAzimuthDeltaDeg(asF(neg['fromDeg']), asF(neg['toDeg'])),
      closeTo(asF(neg['expectDeltaDeg']), tight),
    );
  });
}
