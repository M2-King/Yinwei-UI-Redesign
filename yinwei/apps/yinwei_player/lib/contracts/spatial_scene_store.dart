/// SpatialSceneStore — authoritative SceneContractV1 holder.
///
/// Domain state only. Not wired to EngineController, UI, or Three.js.
library;

import 'dart:convert';

import 'package:yinwei_player/contracts/scene_contract_v1.dart';

enum SceneApplyStatusV1 {
  applied,
  appliedWithDiscontinuity,
  rejectedStale,
  rejectedInvalid,
}

class SceneApplyResultV1 {
  const SceneApplyResultV1({
    required this.status,
    this.reason,
    this.discontinuity = false,
  });

  final SceneApplyStatusV1 status;
  final String? reason;
  final bool discontinuity;

  bool get accepted =>
      status == SceneApplyStatusV1.applied ||
      status == SceneApplyStatusV1.appliedWithDiscontinuity;
}

Map<String, dynamic> _cloneScene(Map<dynamic, dynamic> scene) {
  return jsonDecode(jsonEncode(scene)) as Map<String, dynamic>;
}

/// Holds the last accepted SceneContractV1 snapshot.
///
/// Empty store reports [appliedRevision] `0` (no scene). Incoming revisions
/// are compared with [decideRevisionV1]. Invalid and stale updates leave the
/// previous snapshot unchanged.
class SpatialSceneStore {
  int _appliedRevision = 0;
  Map<String, dynamic>? _scene;

  int get appliedRevision => _appliedRevision;

  bool get hasScene => _scene != null;

  /// Deep copy of the accepted snapshot, or `null` if none.
  Map<String, dynamic>? snapshot() {
    final scene = _scene;
    if (scene == null) return null;
    return _cloneScene(scene);
  }

  SceneApplyResultV1 apply(Map<dynamic, dynamic> incoming) {
    final copy = _cloneScene(incoming);
    final validation = validateSceneV1(copy);
    if (!validation.valid) {
      return SceneApplyResultV1(
        status: SceneApplyStatusV1.rejectedInvalid,
        reason: validation.reason,
      );
    }
    final incomingRevision = copy['revision'] as int;
    final verdict = decideRevisionV1(
      appliedRevision: _appliedRevision,
      incomingRevision: incomingRevision,
    );
    if (!verdict.apply) {
      return const SceneApplyResultV1(
        status: SceneApplyStatusV1.rejectedStale,
        reason: 'stale_revision',
      );
    }
    _scene = copy;
    _appliedRevision = incomingRevision;
    if (verdict.discontinuity) {
      return const SceneApplyResultV1(
        status: SceneApplyStatusV1.appliedWithDiscontinuity,
        discontinuity: true,
      );
    }
    return const SceneApplyResultV1(status: SceneApplyStatusV1.applied);
  }
}
