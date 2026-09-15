/// SpatialRuntimeAdapter — live Point-mode Scene V1 adoption.
///
/// Owns scene-domain state ([SpatialSceneStore]) and revision allocation.
/// Projects accepted snapshots with Dart [AudioProjectionV1] and returns
/// engine-compatible [SpatialParams] for the existing [EngineController]
/// write path. Does not call [EngineApi], FFI, or Three.js.
///
/// Distance boundary:
/// - Scene Store keeps unclamped geometric metres.
/// - `spatial_core::SpatialParams` rejects `distance_m` outside `[0.5, 10]`.
/// - Engine writes therefore use [AudioProjectionV1] `dspDistanceM`.
///
/// Array mode is intentionally not adopted here. Disabled/inactive sources
/// produce no engine write (last engine pose is left unchanged).
library;

import 'dart:convert';

import 'package:yinwei_player/contracts/audio_projection_v1.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/spatial_scene_store.dart';
import 'package:yinwei_player/models/spatial_math.dart';
import 'package:yinwei_player/models/spatial_params.dart';

const String kSpatialListenerIdV1 = 'listener-0';
const String kSpatialPointSourceIdV1 = 'source-main';

class SpatialAdoptionResult {
  const SpatialAdoptionResult({
    this.applyStatus,
    this.sceneAccepted = false,
    this.sceneMutated = false,
    this.pointSourceStatus,
    this.reason,
    this.engineParams,
    this.projection,
  });

  final SceneApplyStatusV1? applyStatus;
  final bool sceneAccepted;
  final bool sceneMutated;
  final PointSourceStatusV1? pointSourceStatus;
  final String? reason;
  final SpatialParams? engineParams;
  final AudioProjectionResultV1? projection;

  bool get shouldWriteEngine => engineParams != null;
}

class SpatialRuntimeAdapter {
  SpatialRuntimeAdapter({
    this.listenerId = kSpatialListenerIdV1,
    this.pointSourceId = kSpatialPointSourceIdV1,
    Map<String, String> emitterBindings = const {},
  }) : config = AudioProjectionConfigV1(
          pointSourceId: pointSourceId,
          emitterBindings: emitterBindings,
        );

  final String listenerId;
  final String pointSourceId;
  final AudioProjectionConfigV1 config;
  final SpatialSceneStore store = SpatialSceneStore();

  SphericalV1? _lastIntentPose;

  bool get hasScene => store.hasScene;

  int get appliedRevision => store.appliedRevision;

  Map<String, dynamic>? snapshot() => store.snapshot();

  SceneApplyResultV1 bootstrap(SpatialParams params) {
    final scene = _buildScene(
      revision: 1,
      pose: _poseOf(params),
    );
    final result = store.apply(scene);
    if (result.accepted) {
      _lastIntentPose = _poseOf(params);
    }
    return result;
  }

  /// Point-mode UI intent. Allocates the next revision when the source pose
  /// changes. Does not read engine telemetry.
  SpatialAdoptionResult adoptPointParams(SpatialParams params) {
    if (!hasScene) {
      final boot = bootstrap(params);
      if (!boot.accepted) {
        return SpatialAdoptionResult(
          applyStatus: boot.status,
          reason: boot.reason,
        );
      }
      return _projectFor(params, applyStatus: boot.status, sceneMutated: true);
    }
    final pose = _poseOf(params);
    if (_samePose(pose, _lastIntentPose)) {
      return _projectFor(params, applyStatus: SceneApplyStatusV1.applied);
    }
    return _applyScene(
      _buildScene(
        revision: store.appliedRevision + 1,
        pose: pose,
        previous: store.snapshot(),
      ),
      intent: params,
    );
  }

  /// Direct scene apply for stale/invalid tests. Not used by Three.js.
  SpatialAdoptionResult tryApplyScene(Map<dynamic, dynamic> scene) {
    return _applyScene(scene, intent: null);
  }

  /// Engine/playback pose readbacks are telemetry. They must not allocate
  /// SceneContract revisions or write the engine.
  void observePlaybackTelemetry({
    double? azimuthDeg,
    double? elevationDeg,
  }) {}

  SpatialAdoptionResult _applyScene(
    Map<dynamic, dynamic> scene, {
    required SpatialParams? intent,
  }) {
    final applied = store.apply(scene);
    if (!applied.accepted) {
      return SpatialAdoptionResult(
        applyStatus: applied.status,
        reason: applied.reason,
      );
    }
    if (intent != null) {
      _lastIntentPose = _poseOf(intent);
    }
    return _projectFor(
      intent,
      applyStatus: applied.status,
      sceneMutated: true,
    );
  }

  SpatialAdoptionResult _projectFor(
    SpatialParams? intent, {
    SceneApplyStatusV1? applyStatus,
    bool sceneMutated = false,
  }) {
    final snap = store.snapshot();
    if (snap == null) {
      return SpatialAdoptionResult(applyStatus: applyStatus);
    }
    final projection = AudioProjectionV1.project(scene: snap, config: config);
    if (projection.pointSourceStatus != PointSourceStatusV1.projected ||
        projection.pointSource == null) {
      return SpatialAdoptionResult(
        applyStatus: applyStatus,
        sceneAccepted: true,
        sceneMutated: sceneMutated,
        pointSourceStatus: projection.pointSourceStatus,
        reason: projection.reason,
        projection: projection,
      );
    }
    final posed = projection.pointSource!;
    final engine = (intent ?? SpatialParams()).copy()
      ..azimuthDeg = posed.azimuthDeg
      ..elevationDeg = posed.elevationDeg
      ..distanceM = posed.dspDistanceM;
    return SpatialAdoptionResult(
      applyStatus: applyStatus,
      sceneAccepted: true,
      sceneMutated: sceneMutated,
      pointSourceStatus: projection.pointSourceStatus,
      engineParams: engine,
      projection: projection,
    );
  }

  Map<String, dynamic> _buildScene({
    required int revision,
    required SphericalV1 pose,
    Map<String, dynamic>? previous,
  }) {
    final sourceWorld = sphericalToLocal(pose);
    final listener = previous == null
        ? _object(
            id: listenerId,
            type: 'listener',
            world: Vec3V1.zero,
            orientation: QuatV1.identity,
          )
        : _cloneMap(previous['listener'] as Map);
    final emitters = previous == null
        ? _visualEmitters()
        : (previous['emitters'] as List)
            .map((e) => _cloneMap(e as Map))
            .toList();
    return {
      'schemaVersion': 1,
      'revision': revision,
      'listener': listener,
      'sources': [
        _object(
          id: kSpatialPointSourceIdV1,
          type: 'source',
          world: sourceWorld,
        ),
      ],
      'emitters': emitters,
    };
  }

  List<Map<String, dynamic>> _visualEmitters() {
    return VisualSpeaker.itu8
        .map(
          (s) => _object(
            id: 'emitter-${s.id}',
            type: 'emitter',
            world: sphericalToLocal(SphericalV1(
              azimuthDeg: s.azimuthDeg,
              elevationDeg: s.elevationDeg,
              distanceM: s.distanceM,
            )),
            visualRole: s.channel,
          ),
        )
        .toList();
  }

  static SphericalV1 _poseOf(SpatialParams params) => SphericalV1(
        azimuthDeg: params.azimuthDeg,
        elevationDeg: params.elevationDeg,
        distanceM: params.distanceM,
      );

  static bool _samePose(SphericalV1 a, SphericalV1? b) {
    if (b == null) return false;
    return a.azimuthDeg == b.azimuthDeg &&
        a.elevationDeg == b.elevationDeg &&
        a.distanceM == b.distanceM;
  }

  static Map<String, dynamic> _cloneMap(Map map) {
    return jsonDecode(jsonEncode(map)) as Map<String, dynamic>;
  }

  static Map<String, dynamic> _object({
    required String id,
    required String type,
    required Vec3V1 world,
    QuatV1? orientation,
    String? visualRole,
  }) {
    return {
      'id': id,
      'type': type,
      'worldPosition': {'x': world.x, 'y': world.y, 'z': world.z},
      if (orientation != null)
        'orientation': {
          'w': orientation.w,
          'x': orientation.x,
          'y': orientation.y,
          'z': orientation.z,
        },
      'enabled': true,
      'active': true,
      if (visualRole != null) 'visualRole': visualRole,
    };
  }
}
