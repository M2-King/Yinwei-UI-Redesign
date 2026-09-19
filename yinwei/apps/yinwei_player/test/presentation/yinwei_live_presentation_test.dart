import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';

void main() {
  test('Live presentation adapter is read-only and does not write the engine',
      () {
    final ctrl = EngineController();
    final writes = ctrl.nativeSpatialWrites;
    final calls = ctrl.spatialSetParamsCalls;
    final origin = ctrl.params.azimuthDeg;

    final presentation = YinweiLivePresentation.read(
      controller: ctrl,
      telemetry: const PlaybackTelemetryV1(
        playing: true,
        orbiting: true,
        azimuthDeg: 41,
        elevationDeg: 8,
      ),
      visualPose: const SphericalV1(
        azimuthDeg: 41,
        elevationDeg: 8,
        distanceM: 1.8,
      ),
    );

    expect(presentation.title, isNotEmpty);
    expect(presentation.playing, isTrue);
    expect(presentation.spatialMode, PlaybackMode.spatial);
    expect(presentation.motionMode, MotionMode.fixed);
    expect(presentation.azimuthDeg, 41);
    expect(presentation.elevationDeg, 8);
    expect(presentation.distanceM, 1.8);
    expect(presentation.orbiting, isTrue);
    expect(ctrl.nativeSpatialWrites, writes);
    expect(ctrl.spatialSetParamsCalls, calls);
    expect(ctrl.params.azimuthDeg, origin);

    final activity = presentation.toActivityView();
    expect(activity.azimuthDeg, 41);
    expect(activity.playing, isTrue);
    expect(activity.orbiting, isTrue);
    ctrl.dispose();
  });
}
