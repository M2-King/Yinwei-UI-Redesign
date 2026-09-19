import 'dart:convert';

import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';

/// Canonical live Orbit overlay. SceneStore stays Point origin authority.
abstract final class OrbitOverlay {
  static bool active({
    required PlaybackMode mode,
    required MotionMode motion,
    required bool playing,
    required bool arrayEnabled,
  }) {
    return mode == PlaybackMode.spatial &&
        motion == MotionMode.orbit &&
        playing &&
        !arrayEnabled;
  }

  static bool ofTelemetry(PlaybackTelemetryV1? telemetry) {
    return telemetry != null && telemetry.orbiting;
  }
}

/// visibleHeading = wrap(origin + phase); origin = wrap(visual - phase).
abstract final class OrbitPoseMath {
  static double phaseDeg({
    required Duration elapsed,
    required double orbitHz,
  }) {
    return elapsed.inMilliseconds / 1000.0 * orbitHz * 360.0;
  }

  static double visualFromOrigin({
    required double originDeg,
    required Duration elapsed,
    required double orbitHz,
  }) {
    return wrapAzimuthDeg(originDeg + phaseDeg(elapsed: elapsed, orbitHz: orbitHz));
  }

  static double originFromVisual({
    required double visualDeg,
    required Duration elapsed,
    required double orbitHz,
  }) {
    return wrapAzimuthDeg(
      visualDeg - phaseDeg(elapsed: elapsed, orbitHz: orbitHz),
    );
  }

  static SphericalV1 storePoseFromVisual({
    required SphericalV1 visual,
    required Duration elapsed,
    required double orbitHz,
    required bool overlayActive,
  }) {
    if (!overlayActive) return visual;
    return SphericalV1(
      azimuthDeg: originFromVisual(
        visualDeg: visual.azimuthDeg,
        elapsed: elapsed,
        orbitHz: orbitHz,
      ),
      elevationDeg: visual.elevationDeg,
      distanceM: visual.distanceM,
    );
  }

  /// Rewrites a Point world-XYZ intent from live heading into SceneStore origin.
  static String rewritePointIntent({
    required String raw,
    required Map scene,
    required Duration elapsed,
    required double orbitHz,
    required bool overlayActive,
  }) {
    if (!overlayActive) return raw;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return raw;
    final data = Map<String, dynamic>.from(decoded);
    final type = data['type'] as String? ?? '';
    if (type != 'sourcePoseCommit' && type != 'sourcePosePreview') {
      return raw;
    }
    final pos = data['worldPosition'];
    if (pos is! Map) return raw;
    final visualScene = Map<String, dynamic>.from(scene);
    final sources = (visualScene['sources'] as List?)
            ?.map((item) => Map<String, dynamic>.from(item as Map))
            .toList() ??
        <Map<String, dynamic>>[];
    for (final source in sources) {
      if (source['id'] == kSpatialPointSourceIdV1) {
        source['worldPosition'] = {
          'x': pos['x'],
          'y': pos['y'],
          'z': pos['z'],
        };
      }
    }
    visualScene['sources'] = sources;
    final visual = IslandPointIntent.pose(visualScene);
    final store = storePoseFromVisual(
      visual: visual,
      elapsed: elapsed,
      orbitHz: orbitHz,
      overlayActive: true,
    );
    data['worldPosition'] = IslandPointIntent.worldOf(scene, store);
    return jsonEncode(data);
  }
}
