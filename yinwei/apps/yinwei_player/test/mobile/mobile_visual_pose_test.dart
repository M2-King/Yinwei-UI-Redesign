import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/mobile/mobile_visual_pose.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';

void main() {
  const origin = SphericalV1(azimuthDeg: 0, elevationDeg: -10, distanceM: 1.8);
  const live = SphericalV1(azimuthDeg: 48, elevationDeg: 6, distanceM: 1.8);

  test('live Spatial Orbit overlay consumes telemetry, not SceneStore', () {
    final pose = MobileVisualPose.resolve(
      scenePose: origin,
      telemetry: PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: live.azimuthDeg,
        elevationDeg: live.elevationDeg,
      ),
      motion: MotionMode.orbit,
      presentation: WorkspacePresentation.point,
      lastLivePose: live,
    );
    expect(pose.azimuthDeg, closeTo(48, 1e-9));
    expect(pose.elevationDeg, closeTo(6, 1e-9));
    expect(pose.distanceM, closeTo(1.8, 1e-9));
  });

  test('pause freezes last live pose instead of jumping to origin', () {
    final pose = MobileVisualPose.resolve(
      scenePose: origin,
      telemetry: const PlaybackTelemetryV1(
        playing: false,
        orbiting: false,
        azimuthDeg: 0,
        elevationDeg: -10,
      ),
      motion: MotionMode.orbit,
      presentation: WorkspacePresentation.point,
      lastLivePose: live,
    );
    expect(pose.azimuthDeg, closeTo(48, 1e-9));
    expect(pose.elevationDeg, closeTo(6, 1e-9));
  });

  test('idle without a live pose uses SceneStore origin', () {
    final pose = MobileVisualPose.resolve(
      scenePose: origin,
      telemetry: const PlaybackTelemetryV1(),
      motion: MotionMode.orbit,
      presentation: WorkspacePresentation.point,
    );
    expect(pose.azimuthDeg, closeTo(0, 1e-9));
    expect(pose.elevationDeg, closeTo(-10, 1e-9));
  });

  test('Fixed mode always uses SceneStore pose', () {
    final pose = MobileVisualPose.resolve(
      scenePose: origin,
      telemetry: const PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: 99,
        elevationDeg: 12,
      ),
      motion: MotionMode.fixed,
      presentation: WorkspacePresentation.point,
      lastLivePose: live,
    );
    expect(pose.azimuthDeg, closeTo(0, 1e-9));
    expect(pose.elevationDeg, closeTo(-10, 1e-9));
  });

  test('Stereo 2.0 does not consume Point Orbit overlay', () {
    final pose = MobileVisualPose.resolve(
      scenePose: origin,
      telemetry: const PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: 99,
        elevationDeg: 12,
      ),
      motion: MotionMode.orbit,
      presentation: WorkspacePresentation.stereo2,
      lastLivePose: live,
    );
    expect(pose.azimuthDeg, closeTo(0, 1e-9));
    expect(OrbitOverlay.active(
      mode: PlaybackMode.spatial,
      motion: MotionMode.orbit,
      playing: true,
      arrayEnabled: true,
    ), isFalse);
  });
}
