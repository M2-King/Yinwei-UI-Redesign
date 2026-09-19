/// SpatialSceneBridge — Flutter ↔ Three.js intent/snapshot protocol.
///
/// Flutter [SpatialSceneStore] is the only scene authority. JavaScript proposes
/// intents; this bridge accepts or rejects them, then publishes snapshots.
///
/// Does not own DSP, transport, playback, native FFI, or visual styling.
/// Does not write [EngineApi]. Callers apply [SceneBridgeResult.engineParams]
/// through the existing Point engine path.
library;

import 'dart:convert';

import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';

/// Domain Hamilton `(w,x,y,z)` → Three.js `(x,y,z,w)` at the JS boundary only.
Map<String, double> domainQuatToThreeJs(Map q) {
  return {
    'x': (q['x'] as num).toDouble(),
    'y': (q['y'] as num).toDouble(),
    'z': (q['z'] as num).toDouble(),
    'w': (q['w'] as num).toDouble(),
  };
}

/// Three.js `(x,y,z,w)` → domain Hamilton `(w,x,y,z)`.
Map<String, double> threeJsQuatToDomain(Map q) {
  return {
    'w': (q['w'] as num).toDouble(),
    'x': (q['x'] as num).toDouble(),
    'y': (q['y'] as num).toDouble(),
    'z': (q['z'] as num).toDouble(),
  };
}

class PlaybackTelemetryV1 {
  const PlaybackTelemetryV1({
    this.playhead = 0,
    this.playing = false,
    this.orbiting = false,
    this.envelopment = 0,
    this.active = true,
    this.azimuthDeg = 0,
    this.elevationDeg = 0,
  });

  final double playhead;
  final bool playing;
  final bool orbiting;
  final double envelopment;
  final bool active;
  final double azimuthDeg;
  final double elevationDeg;

  @override
  bool operator ==(Object other) {
    return other is PlaybackTelemetryV1 &&
        playhead == other.playhead &&
        playing == other.playing &&
        orbiting == other.orbiting &&
        envelopment == other.envelopment &&
        active == other.active &&
        azimuthDeg == other.azimuthDeg &&
        elevationDeg == other.elevationDeg;
  }

  @override
  int get hashCode => Object.hash(
        playhead,
        playing,
        orbiting,
        envelopment,
        active,
        azimuthDeg,
        elevationDeg,
      );

  Map<String, dynamic> toHostMessage() => {
        'type': 'playbackTelemetry',
        'playhead': playhead,
        'playing': playing,
        'orbiting': orbiting,
        'envelopment': envelopment,
        'active': active,
        'azimuthDeg': azimuthDeg,
        'elevationDeg': elevationDeg,
      };
}

class SceneBridgeResult {
  const SceneBridgeResult({
    this.accepted = false,
    this.sceneMutated = false,
    this.reason,
    this.applyStatus,
    this.engineParams,
    this.outgoing = const [],
    this.selectedObjectId,
  });

  final bool accepted;
  final bool sceneMutated;
  final String? reason;
  final SceneApplyStatusV1? applyStatus;
  final SpatialParams? engineParams;
  final List<Map<String, dynamic>> outgoing;
  final String? selectedObjectId;

  bool get shouldWriteEngine => engineParams != null;
}

/// Canonical create/update/remove registry used by tests and mirrored in JS.
class SpatialRendererRegistry {
  final Map<String, Map<String, dynamic>> objectsById = {};
  final Map<String, int> _creates = {};
  int rebuildSpeakers = 0;

  bool contains(String id) => objectsById.containsKey(id);

  int createCount(String id) => _creates[id] ?? 0;

  Map<String, dynamic>? positionOf(String id) {
    final pos = objectsById[id]?['worldPosition'];
    if (pos is Map<String, dynamic>) return pos;
    if (pos is Map) return Map<String, dynamic>.from(pos);
    return null;
  }

  bool _orbitOverlay = false;

  void applySceneSnapshot(Map scene) {
    final incoming = <String, Map<String, dynamic>>{};
    void add(Object? raw) {
      if (raw is! Map) return;
      final obj = Map<String, dynamic>.from(raw);
      final id = obj['id'];
      if (id is! String) return;
      incoming[id] = obj;
    }

    add(scene['listener']);
    for (final item in (scene['sources'] as List? ?? const [])) {
      add(item);
    }
    for (final item in (scene['emitters'] as List? ?? const [])) {
      add(item);
    }
    for (final id in incoming.keys) {
      final previousPos = objectsById[id]?['worldPosition'];
      if (!objectsById.containsKey(id)) {
        _creates[id] = (_creates[id] ?? 0) + 1;
      }
      objectsById[id] = incoming[id]!;
      if (_orbitOverlay &&
          id == kSpatialPointSourceIdV1 &&
          previousPos != null) {
        objectsById[id]!['worldPosition'] = previousPos;
      }
    }
    objectsById.removeWhere((id, _) => !incoming.containsKey(id));
  }

  void applyPlaybackTelemetry(Map telemetry) {
    // Playback is visual overlay only. Never rebuild emitters or allocate IDs.
    _orbitOverlay = telemetry['orbiting'] == true;
    if (!_orbitOverlay) return;
    final az = telemetry['azimuthDeg'];
    final el = telemetry['elevationDeg'];
    if (az is! num || el is! num) return;
    final source = objectsById[kSpatialPointSourceIdV1];
    if (source == null) return;
    final pos = source['worldPosition'];
    if (pos is! Map) return;
    final current = Vec3V1(
      (pos['x'] as num).toDouble(),
      (pos['y'] as num).toDouble(),
      (pos['z'] as num).toDouble(),
    );
    final world = sphericalToLocal(
      SphericalV1(
        azimuthDeg: az.toDouble(),
        elevationDeg: el.toDouble(),
        distanceM: geometricDistanceM(current),
      ),
    );
    source['worldPosition'] = {'x': world.x, 'y': world.y, 'z': world.z};
  }
}

class SpatialSceneBridge {
  SpatialSceneBridge({required this.adapter});

  final SpatialRuntimeAdapter adapter;
  String? selectedObjectId;
  PlaybackTelemetryV1 telemetry = const PlaybackTelemetryV1();
  bool _disposed = false;

  bool get disposed => _disposed;

  void dispose() {
    _disposed = true;
  }

  void observePlaybackTelemetry({
    required double playhead,
    required bool playing,
    bool orbiting = false,
    double envelopment = 0,
    bool active = true,
    double azimuthDeg = 0,
    double elevationDeg = 0,
  }) {
    telemetry = PlaybackTelemetryV1(
      playhead: playhead,
      playing: playing,
      orbiting: orbiting,
      envelopment: envelopment,
      active: active,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    );
  }

  Map<String, dynamic> sceneSnapshotMessage() {
    final scene = adapter.snapshot() ?? <String, dynamic>{};
    return {
      'type': 'sceneSnapshot',
      'schemaVersion': scene['schemaVersion'] ?? 1,
      'revision': adapter.appliedRevision,
      'scene': scene,
    };
  }

  Map<String, dynamic> playbackTelemetryMessage() => telemetry.toHostMessage();

  Map<String, dynamic> uiStateMessage() {
    return {
      'type': 'uiState',
      'selectedObjectId': selectedObjectId,
    };
  }

  SceneBridgeResult handleMessage(String raw) {
    if (_disposed) return const SceneBridgeResult();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const SceneBridgeResult(reason: 'malformed');
    }
    if (decoded is! Map) {
      return const SceneBridgeResult(reason: 'malformed');
    }
    final data = Map<String, dynamic>.from(decoded);
    switch (data['type'] as String? ?? '') {
      case 'ready':
        return SceneBridgeResult(
          accepted: true,
          outgoing: [
            sceneSnapshotMessage(),
            playbackTelemetryMessage(),
            uiStateMessage(),
          ],
        );
      case 'selectObject':
        selectedObjectId = data['objectId'] as String?;
        return SceneBridgeResult(
          accepted: true,
          selectedObjectId: selectedObjectId,
          outgoing: [uiStateMessage()],
        );
      case 'cameraMoved':
        return const SceneBridgeResult(accepted: true);
      case 'playbackTelemetry':
        return const SceneBridgeResult(accepted: true);
      case 'sourcePosePreview':
        return _handleSourcePose(data, commit: false);
      case 'sourcePoseCommit':
        return _handleSourcePose(data, commit: true);
      default:
        return const SceneBridgeResult(reason: 'unknown_type');
    }
  }

  SceneBridgeResult _handleSourcePose(
    Map<String, dynamic> data, {
    required bool commit,
  }) {
    // JS may include newRevision/revision; Flutter ignores them.
    final objectId = data['objectId'] as String? ?? '';
    final basedOn = data['basedOnRevision'];
    final basedOnRevision = basedOn is int
        ? basedOn
        : basedOn is num
            ? basedOn.toInt()
            : int.tryParse('$basedOn');
    final pos = data['worldPosition'];
    if (basedOnRevision == null || pos is! Map) {
      return _reject(
        reason: 'invalid_coordinates',
        status: SceneApplyStatusV1.rejectedInvalid,
      );
    }
    final x = _finite(pos['x']);
    final y = _finite(pos['y']);
    final z = _finite(pos['z']);
    if (x == null || y == null || z == null) {
      return _reject(
        reason: 'invalid_coordinates',
        status: SceneApplyStatusV1.rejectedInvalid,
      );
    }
    final adopted = adapter.adoptSourceWorld(
      objectId: objectId,
      world: Vec3V1(x, y, z),
      basedOnRevision: basedOnRevision,
      commit: commit,
    );
    if (adopted.reason == 'stale_revision' ||
        adopted.applyStatus == SceneApplyStatusV1.rejectedStale) {
      return _reject(
        reason: 'stale_revision',
        status: SceneApplyStatusV1.rejectedStale,
      );
    }
    if (adopted.reason == 'unknown_object') {
      return _reject(
        reason: 'unknown_object',
        status: SceneApplyStatusV1.rejectedInvalid,
      );
    }
    if (adopted.reason == 'invalid_coordinates' ||
        adopted.applyStatus == SceneApplyStatusV1.rejectedInvalid) {
      return _reject(
        reason: adopted.reason ?? 'invalid_coordinates',
        status: SceneApplyStatusV1.rejectedInvalid,
      );
    }
    if (!adopted.sceneAccepted) {
      return _reject(
        reason: adopted.reason ?? 'rejected',
        status: adopted.applyStatus,
      );
    }
    if (!commit) {
      return SceneBridgeResult(
        accepted: true,
        sceneMutated: false,
        applyStatus: adopted.applyStatus,
        engineParams: adopted.engineParams,
      );
    }
    return SceneBridgeResult(
      accepted: true,
      sceneMutated: adopted.sceneMutated,
      applyStatus: adopted.applyStatus,
      engineParams: adopted.engineParams,
      outgoing: [sceneSnapshotMessage()],
    );
  }

  SceneBridgeResult _reject({
    required String reason,
    SceneApplyStatusV1? status,
  }) {
    return SceneBridgeResult(
      reason: reason,
      applyStatus: status,
      outgoing: [sceneSnapshotMessage()],
    );
  }

  static double? _finite(Object? value) {
    if (value is! num) return null;
    final n = value.toDouble();
    if (!n.isFinite) return null;
    return n;
  }
}
