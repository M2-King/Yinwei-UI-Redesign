import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/live_activity_bridge.dart';
import 'package:yinwei_player/platform/live_activity_coordinator.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _RecordingBridge implements LiveActivityBridge {
  final starts = <YinweiLivePresentation>[];
  final updates = <YinweiLivePresentation>[];
  var ends = 0;

  @override
  bool get available => true;

  @override
  Future<void> start(YinweiLivePresentation presentation) async {
    starts.add(presentation);
  }

  @override
  Future<void> update(YinweiLivePresentation presentation) async {
    updates.add(presentation);
  }

  @override
  Future<void> end() async {
    ends++;
  }
}

YinweiLivePresentation _pose({
  String title = 'Track',
  bool playing = true,
  double azimuth = 40,
  double elevation = 0,
  double distance = 1.8,
  bool orbiting = true,
}) {
  return YinweiLivePresentation(
    title: title,
    playing: playing,
    spatialMode: PlaybackMode.spatial,
    motionMode: MotionMode.orbit,
    azimuthDeg: azimuth,
    elevationDeg: elevation,
    distanceM: distance,
    orbiting: orbiting,
  );
}

void main() {
  test('duplicate presentation state does not spam updates', () async {
    final bridge = _RecordingBridge();
    final coordinator = LiveActivityCoordinator(bridge: bridge);
    final first = _pose();
    await coordinator.publish(first);
    await coordinator.publish(first);
    await coordinator.publish(_pose());
    expect(bridge.starts, hasLength(1));
    expect(bridge.updates, isEmpty);
  });

  test('heading-only changes are throttled', () async {
    var now = DateTime.utc(2026, 9, 19, 12);
    final bridge = _RecordingBridge();
    final coordinator = LiveActivityCoordinator(
      bridge: bridge,
      now: () => now,
    );
    await coordinator.publish(_pose(azimuth: 10));
    now = now.add(const Duration(milliseconds: 80));
    await coordinator.publish(_pose(azimuth: 18));
    expect(bridge.starts, hasLength(1));
    expect(bridge.updates, isEmpty);

    now = now.add(const Duration(milliseconds: 250));
    await coordinator.publish(_pose(azimuth: 26));
    expect(bridge.updates, hasLength(1));
    expect(bridge.updates.single.azimuthDeg, 26);
  });

  test('playing or title changes bypass heading throttle', () async {
    var now = DateTime.utc(2026, 9, 19, 12);
    final bridge = _RecordingBridge();
    final coordinator = LiveActivityCoordinator(
      bridge: bridge,
      now: () => now,
    );
    await coordinator.publish(_pose(playing: true, azimuth: 10));
    now = now.add(const Duration(milliseconds: 40));
    await coordinator.publish(_pose(playing: false, azimuth: 10));
    expect(bridge.updates, hasLength(1));
    expect(bridge.updates.single.playing, isFalse);
  });

  test('Live Activity updates do not write SceneStore or EngineApi', () async {
    final ctrl = EngineController();
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    final writes = ctrl.nativeSpatialWrites;
    final calls = ctrl.spatialSetParamsCalls;
    final rev = adapter.appliedRevision;
    final bridge = _RecordingBridge();
    final coordinator = LiveActivityCoordinator(bridge: bridge);

    await coordinator.publish(
      YinweiLivePresentation.read(
        controller: ctrl,
        telemetry: const PlaybackTelemetryV1(
          playing: true,
          orbiting: true,
          azimuthDeg: 55,
          elevationDeg: 4,
        ),
        visualPose: const SphericalV1(
          azimuthDeg: 55,
          elevationDeg: 4,
          distanceM: 1.8,
        ),
      ),
    );

    expect(bridge.starts, hasLength(1));
    expect(adapter.appliedRevision, rev);
    expect(ctrl.nativeSpatialWrites, writes);
    expect(ctrl.spatialSetParamsCalls, calls);
    expect(ctrl.params.azimuthDeg, isNot(55));
    ctrl.dispose();
  });
}
