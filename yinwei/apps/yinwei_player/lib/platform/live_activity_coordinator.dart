import 'package:yinwei_player/platform/live_activity_bridge.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';

/// Owns Live Activity start/update/end above the mobile UI.
///
/// Dedupes identical payloads and throttles heading-only Orbit motion so
/// Flutter animation / telemetry ticks cannot spam ActivityKit.
class LiveActivityCoordinator {
  LiveActivityCoordinator({
    required this.bridge,
    this.headingMinInterval = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LiveActivityBridge bridge;
  final Duration headingMinInterval;
  final DateTime Function() _now;

  YinweiLivePresentation? _lastSent;
  DateTime? _lastSentAt;
  var _started = false;

  Future<void> publish(YinweiLivePresentation presentation) async {
    if (!bridge.available) return;
    final last = _lastSent;
    if (last == presentation) return;
    if (last != null &&
        _headingOnly(last, presentation) &&
        !_headingIntervalElapsed()) {
      return;
    }
    if (!_started) {
      await bridge.start(presentation);
      _started = true;
    } else {
      await bridge.update(presentation);
    }
    _lastSent = presentation;
    _lastSentAt = _now();
  }

  Future<void> end() async {
    if (!_started) return;
    await bridge.end();
    _started = false;
    _lastSent = null;
    _lastSentAt = null;
  }

  bool _headingIntervalElapsed() {
    final sentAt = _lastSentAt;
    if (sentAt == null) return true;
    return _now().difference(sentAt) >= headingMinInterval;
  }

  static bool _headingOnly(
    YinweiLivePresentation previous,
    YinweiLivePresentation next,
  ) {
    return previous.title == next.title &&
        previous.playing == next.playing &&
        previous.spatialMode == next.spatialMode &&
        previous.motionMode == next.motionMode &&
        previous.orbiting == next.orbiting &&
        (previous.azimuthDeg != next.azimuthDeg ||
            previous.elevationDeg != next.elevationDeg ||
            previous.distanceM != next.distanceM);
  }
}
