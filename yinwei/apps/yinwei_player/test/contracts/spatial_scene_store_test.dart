import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/scene_contract_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';

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
    if (orientation != null) 'orientation': orientation,
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
  Map<String, Object>? extra,
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
          _object(id: 'source-0', type: 'source', z: -1.8),
        ],
    'emitters': emitters ?? const <Map<String, dynamic>>[],
    if (extra != null) ...extra,
  };
}

void main() {
  test('1 valid first scene accepted', () {
    final store = SpatialSceneStore();
    expect(store.hasScene, isFalse);
    expect(store.appliedRevision, 0);
    final result = store.apply(_scene());
    expect(result.status, SceneApplyStatusV1.applied);
    expect(store.hasScene, isTrue);
    expect(store.appliedRevision, 1);
    expect(store.snapshot()!['revision'], 1);
  });

  test('1b empty store accepts valid revision 0', () {
    final store = SpatialSceneStore();
    expect(store.hasScene, isFalse);
    final result = store.apply(_scene(revision: 0));
    expect(result.status, SceneApplyStatusV1.applied);
    expect(result.discontinuity, isFalse);
    expect(store.hasScene, isTrue);
    expect(store.appliedRevision, 0);
    expect(store.snapshot()!['revision'], 0);
  });

  test('1c revision 0 again is rejected stale', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 0));
    final result = store.apply(_scene(revision: 0, sources: [
      _object(id: 'source-other', type: 'source', x: 9),
    ]));
    expect(result.status, SceneApplyStatusV1.rejectedStale);
    expect(store.appliedRevision, 0);
    expect((store.snapshot()!['sources'] as List).first['id'], 'source-0');
  });

  test('1d revision 1 after revision 0 is applied', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 0));
    final result = store.apply(_scene(revision: 1, sources: [
      _object(id: 'source-0', type: 'source', z: -2),
    ]));
    expect(result.status, SceneApplyStatusV1.applied);
    expect(result.discontinuity, isFalse);
    expect(store.appliedRevision, 1);
    expect((store.snapshot()!['sources'] as List).first['worldPosition']['z'], -2);
  });

  test('2 newer sequential revision accepted', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    final result = store.apply(_scene(revision: 2, sources: [
      _object(id: 'source-0', type: 'source', z: -2),
    ]));
    expect(result.status, SceneApplyStatusV1.applied);
    expect(result.discontinuity, isFalse);
    expect(store.appliedRevision, 2);
    expect((store.snapshot()!['sources'] as List).first['worldPosition']['z'], -2);
  });

  test('3 equal revision rejected', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    final result = store.apply(_scene(revision: 1, sources: [
      _object(id: 'source-other', type: 'source', x: 9),
    ]));
    expect(result.status, SceneApplyStatusV1.rejectedStale);
    expect(store.appliedRevision, 1);
    expect((store.snapshot()!['sources'] as List).first['id'], 'source-0');
  });

  test('4 older revision rejected', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 2));
    final result = store.apply(_scene(revision: 1));
    expect(result.status, SceneApplyStatusV1.rejectedStale);
    expect(store.appliedRevision, 2);
  });

  test('5 revision gap accepted but flagged', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    final result = store.apply(_scene(revision: 4));
    expect(result.status, SceneApplyStatusV1.appliedWithDiscontinuity);
    expect(result.discontinuity, isTrue);
    expect(store.appliedRevision, 4);
  });

  test('6 invalid scene rejected', () {
    final store = SpatialSceneStore();
    final result = store.apply({'schemaVersion': 1, 'revision': 1});
    expect(result.status, SceneApplyStatusV1.rejectedInvalid);
    expect(store.hasScene, isFalse);
  });

  test('7 previous valid scene retained after rejected update', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    store.apply({
      ..._scene(revision: 2),
      'camera': {'distance': 5},
    });
    expect(store.appliedRevision, 1);
    expect(store.snapshot()!.containsKey('camera'), isFalse);
  });

  test('8 stable IDs preserved', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    store.apply(_scene(revision: 2, sources: [
      _object(id: 'source-0', type: 'source', z: -3),
    ]));
    expect(store.snapshot()!['listener']['id'], 'listener-0');
    expect((store.snapshot()!['sources'] as List).first['id'], 'source-0');
  });

  test('9 forbidden UI/audio state remains outside store', () {
    final store = SpatialSceneStore();
    store.apply(_scene(revision: 1));
    final fixture = loadContractFixture('scene_fixtures_v1.json');
    expect(fixture['forbiddenTopLevelKeys'], kForbiddenSceneTopLevelKeysV1);
    for (final key in kForbiddenSceneTopLevelKeysV1) {
      final result = store.apply({
        ..._scene(revision: store.appliedRevision + 1),
        key: {'x': 1},
      });
      expect(result.status, SceneApplyStatusV1.rejectedInvalid, reason: key);
      expect(result.reason, 'forbidden_key');
    }
    expect(store.appliedRevision, 1);
    final snap = store.snapshot()!;
    for (final key in kForbiddenSceneTopLevelKeysV1) {
      expect(snap.containsKey(key), isFalse);
    }
  });
}
