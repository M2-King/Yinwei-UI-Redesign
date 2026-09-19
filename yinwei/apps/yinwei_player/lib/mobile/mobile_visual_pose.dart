import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';

/// Presentation-only Point pose for the iPhone surface.
///
/// Live telemetry may overlay SceneStore while Spatial+Orbit is playing.
/// This helper never writes SceneStore, EngineApi, or DSP state.
abstract final class MobileVisualPose {
  static SphericalV1 resolve({
    required SphericalV1 scenePose,
    required PlaybackTelemetryV1 telemetry,
    required MotionMode motion,
    required WorkspacePresentation presentation,
    SphericalV1? lastLivePose,
  }) {
    if (presentation != WorkspacePresentation.point) {
      return scenePose;
    }
    if (motion != MotionMode.orbit) {
      return scenePose;
    }
    if (OrbitOverlay.ofTelemetry(telemetry)) {
      return SphericalV1(
        azimuthDeg: telemetry.azimuthDeg,
        elevationDeg: telemetry.elevationDeg,
        distanceM: scenePose.distanceM,
      );
    }
    if (!telemetry.playing && lastLivePose != null) {
      return lastLivePose;
    }
    return scenePose;
  }
}
