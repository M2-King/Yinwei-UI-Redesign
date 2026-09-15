/// SceneContractV1 — authoritative Spatial Scene Domain document.
///
/// Isolated from audio configuration, UI selection, camera, and telemetry.
library;

const int kSceneSchemaVersionV1 = 1;
const int kMaxSourcesV1 = 32;
const int kMaxEmittersV1 = 8;
const int kMaxIdLengthV1 = 64;
const double kQuatDegenerateNormV1 = 1e-12;

const List<String> kForbiddenSceneTopLevelKeysV1 = [
  'camera',
  'selection',
  'hover',
  'drag',
  'telemetry',
  'audio',
  'spatialParams',
  'arrayLayout',
];

final _idPattern = RegExp(r'^[A-Za-z0-9_\-:.]+$');

class SceneValidationV1 {
  const SceneValidationV1.valid()
      : valid = true,
        reason = null;

  const SceneValidationV1.invalid(this.reason) : valid = false;

  final bool valid;
  final String? reason;
}

enum RevisionDecisionV1 { apply, rejectStale }

class RevisionVerdictV1 {
  const RevisionVerdictV1({
    required this.decision,
    required this.discontinuity,
  });

  final RevisionDecisionV1 decision;
  final bool discontinuity;

  bool get apply => decision == RevisionDecisionV1.apply;
}

RevisionVerdictV1 decideRevisionV1({
  required int appliedRevision,
  required int incomingRevision,
}) {
  if (incomingRevision <= appliedRevision) {
    return const RevisionVerdictV1(
      decision: RevisionDecisionV1.rejectStale,
      discontinuity: false,
    );
  }
  return RevisionVerdictV1(
    decision: RevisionDecisionV1.apply,
    discontinuity: incomingRevision > appliedRevision + 1,
  );
}

bool _isFiniteNum(Object? v) {
  if (v is! num) return false;
  return v.isFinite;
}

bool _validId(Object? id) {
  if (id is! String) return false;
  if (id.isEmpty || id.length > kMaxIdLengthV1) return false;
  return _idPattern.hasMatch(id);
}

String? _validateObject(
  Map<dynamic, dynamic> obj, {
  required String expectedType,
}) {
  if (!_validId(obj['id'])) return 'invalid_id';
  if (obj['type'] != expectedType) return 'wrong_type';
  final pos = obj['worldPosition'];
  if (pos is! Map) return 'non_finite_position';
  if (!_isFiniteNum(pos['x']) ||
      !_isFiniteNum(pos['y']) ||
      !_isFiniteNum(pos['z'])) {
    return 'non_finite_position';
  }
  if (obj['enabled'] is! bool || obj['active'] is! bool) {
    return 'invalid_flags';
  }
  if (obj.containsKey('orientation')) {
    final q = obj['orientation'];
    if (q is! Map) return 'invalid_orientation';
    if (!_isFiniteNum(q['w']) ||
        !_isFiniteNum(q['x']) ||
        !_isFiniteNum(q['y']) ||
        !_isFiniteNum(q['z'])) {
      return 'invalid_orientation';
    }
    final w = (q['w'] as num).toDouble();
    final x = (q['x'] as num).toDouble();
    final y = (q['y'] as num).toDouble();
    final z = (q['z'] as num).toDouble();
    final n = w * w + x * x + y * y + z * z;
    if (n < kQuatDegenerateNormV1 * kQuatDegenerateNormV1) {
      return 'invalid_orientation';
    }
  }
  return null;
}

SceneValidationV1 validateSceneV1(Map<dynamic, dynamic> scene) {
  for (final key in kForbiddenSceneTopLevelKeysV1) {
    if (scene.containsKey(key)) {
      return const SceneValidationV1.invalid('forbidden_key');
    }
  }
  if (scene['schemaVersion'] != kSceneSchemaVersionV1) {
    return const SceneValidationV1.invalid('schema_version');
  }
  final rev = scene['revision'];
  if (rev is! int || rev < 0) {
    return const SceneValidationV1.invalid('invalid_revision');
  }

  final listener = scene['listener'];
  if (listener is! Map) {
    return const SceneValidationV1.invalid('missing_listener');
  }
  final listenerErr = _validateObject(listener, expectedType: 'listener');
  if (listenerErr != null) {
    return SceneValidationV1.invalid(listenerErr);
  }

  final sources = scene['sources'];
  final emitters = scene['emitters'];
  if (sources is! List || emitters is! List) {
    return const SceneValidationV1.invalid('invalid_collections');
  }
  if (sources.length > kMaxSourcesV1) {
    return const SceneValidationV1.invalid('too_many_sources');
  }
  if (emitters.length > kMaxEmittersV1) {
    return const SceneValidationV1.invalid('too_many_emitters');
  }

  final ids = <String>{};
  void addId(String id) => ids.add(id);
  addId(listener['id'] as String);

  for (final item in sources) {
    if (item is! Map) {
      return const SceneValidationV1.invalid('invalid_object');
    }
    final err = _validateObject(item, expectedType: 'source');
    if (err != null) return SceneValidationV1.invalid(err);
    final id = item['id'] as String;
    if (!ids.add(id)) {
      return const SceneValidationV1.invalid('duplicate_id');
    }
  }
  for (final item in emitters) {
    if (item is! Map) {
      return const SceneValidationV1.invalid('invalid_object');
    }
    final err = _validateObject(item, expectedType: 'emitter');
    if (err != null) return SceneValidationV1.invalid(err);
    final id = item['id'] as String;
    if (!ids.add(id)) {
      return const SceneValidationV1.invalid('duplicate_id');
    }
  }
  return const SceneValidationV1.valid();
}
