import 'package:yinwei_player/bridge/yinwei_activity_presentation.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';

/// Read-only handoff model for the native Live Activity / Dynamic Island.
///
/// Not audio authority. Does not write SceneStore, EngineApi, or DSP.
class YinweiLivePresentation {
  const YinweiLivePresentation({
    required this.title,
    required this.playing,
    required this.spatialMode,
    required this.motionMode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.orbiting,
  });

  final String title;
  final bool playing;
  final PlaybackMode spatialMode;
  final MotionMode motionMode;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final bool orbiting;

  /// Snapshot existing controller/telemetry/visual state. Never mutates it.
  factory YinweiLivePresentation.read({
    required EngineController controller,
    required PlaybackTelemetryV1 telemetry,
    required SphericalV1 visualPose,
  }) {
    return YinweiLivePresentation(
      title: controller.track.title,
      playing: telemetry.playing,
      spatialMode: controller.mode,
      motionMode: controller.params.motion,
      azimuthDeg: visualPose.azimuthDeg,
      elevationDeg: visualPose.elevationDeg,
      distanceM: visualPose.distanceM,
      orbiting: telemetry.orbiting,
    );
  }

  YinweiActivityViewState toActivityView() {
    return YinweiActivityViewState(
      mode: spatialMode == PlaybackMode.spatial ? 'spatial' : 'original',
      playing: playing,
      orbiting: orbiting,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
      sourceLabel: 'Point',
      title: title,
    );
  }

  Map<String, dynamic> toChannelPayload() => {
        'title': title,
        'playing': playing,
        'spatialMode': spatialMode.name,
        'motionMode': motionMode.name,
        'azimuthDeg': azimuthDeg,
        'elevationDeg': elevationDeg,
        'distanceM': distanceM,
        'orbiting': orbiting,
      };

  @override
  bool operator ==(Object other) {
    return other is YinweiLivePresentation &&
        title == other.title &&
        playing == other.playing &&
        spatialMode == other.spatialMode &&
        motionMode == other.motionMode &&
        azimuthDeg == other.azimuthDeg &&
        elevationDeg == other.elevationDeg &&
        distanceM == other.distanceM &&
        orbiting == other.orbiting;
  }

  @override
  int get hashCode => Object.hash(
        title,
        playing,
        spatialMode,
        motionMode,
        azimuthDeg,
        elevationDeg,
        distanceM,
        orbiting,
      );
}
