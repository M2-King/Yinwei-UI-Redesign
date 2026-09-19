import 'dart:convert';
import 'dart:math' as math;
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';

/// Read-only coordinate adapter. No scene store, pose cache or engine access.
abstract final class IslandPointIntent {
  static Vec3V1 _vec(Map p) => Vec3V1((p['x'] as num).toDouble(),
      (p['y'] as num).toDouble(), (p['z'] as num).toDouble());

  static ListenerPoseV1 listener(Map scene) {
    final raw = scene['listener'] as Map;
    final q = raw['orientation'] as Map?;
    return ListenerPoseV1(
        worldPosition: _vec(raw['worldPosition'] as Map),
        orientation: q == null
            ? QuatV1.identity
            : QuatV1((q['w'] as num).toDouble(), (q['x'] as num).toDouble(),
                (q['y'] as num).toDouble(), (q['z'] as num).toDouble()));
  }

  static SphericalV1 pose(Map scene) {
    final source = (scene['sources'] as List)
        .cast<Map>()
        .firstWhere((s) => s['id'] == kSpatialPointSourceIdV1);
    return localToSpherical(worldToListenerLocal(
        _vec(source['worldPosition'] as Map), listener(scene)));
  }

  static String commit(Map scene, SphericalV1 pose) {
    return jsonEncode({
      'type': 'sourcePoseCommit',
      'objectId': kSpatialPointSourceIdV1,
      'basedOnRevision': scene['revision'],
      'worldPosition': worldOf(scene, pose),
    });
  }

  static Map<String, double> worldOf(Map scene, SphericalV1 pose) {
    final world = listenerLocalToWorld(sphericalToLocal(pose), listener(scene));
    return {'x': world.x, 'y': world.y, 'z': world.z};
  }

  /// The circular control uses spherical metres as its radius, not projected
  /// ground-plane distance. Elevation stays independent, including at poles.
  /// Screen +Y is down: atan2(dx, -dy) preserves 0 front / +90 right.
  static SphericalV1 fromPad(
      {required double dx,
      required double dy,
      required double radius,
      required double rangeM,
      required double elevationDeg,
      double previousAzimuth = 0}) {
    final r = math.sqrt(dx * dx + dy * dy);
    return SphericalV1(
        azimuthDeg: r < 1e-9
            ? previousAzimuth
            : wrapAzimuthDeg(math.atan2(dx, -dy) * 180 / math.pi),
        elevationDeg: elevationDeg,
        distanceM: r / radius * rangeM);
  }
}

/// Read-only orbit overlay. Does not write SceneStore or EngineApi.
abstract final class OrbitVisualPose {
  static SphericalV1 resolve({
    required SphericalV1 scenePose,
    PlaybackTelemetryV1? telemetry,
  }) {
    final tel = telemetry;
    if (tel == null || !tel.orbiting) return scenePose;
    return SphericalV1(
      azimuthDeg: tel.azimuthDeg,
      elevationDeg: tel.elevationDeg,
      distanceM: scenePose.distanceM,
    );
  }
}
