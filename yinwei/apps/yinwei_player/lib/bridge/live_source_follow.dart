import 'package:yinwei_player/bridge/system_media.dart';

/// When Full-window Transfer is ON, follow a new SMTC music source.
///
/// Same-app next-track (title change, same pid) must not restart capture or
/// re-run the PowerShell speaker pin. A different pid/process should.
class LiveSourceFollow {
  static const debounce = Duration(milliseconds: 600);

  static bool isYinweiProcess(String processName) {
    final p = processName.toLowerCase();
    return p.contains('yinwei') || p.contains('flutter');
  }

  static bool isFollowablePid(SystemMediaState smtc) {
    if (smtc.pid <= 0) return false;
    if (isYinweiProcess(smtc.processName)) return false;
    return true;
  }

  /// WASAPI loopback should bind to [smtc.pid] instead of [capturePid].
  static bool shouldRetargetCapture({
    required bool transferOn,
    required int capturePid,
    required SystemMediaState smtc,
    required bool captureHealthy,
  }) {
    if (!transferOn) return false;
    if (!isFollowablePid(smtc)) return false;
    if (smtc.pid == capturePid) return false;
    return smtc.playing || !captureHealthy;
  }

  /// Move the muted-speaker pin from [routedPid] to the new music app tree.
  /// Title-only / next-track (same pid) never re-runs the pin.
  static bool shouldRetargetRoute({
    required bool transferOn,
    required bool splitActive,
    required int routedPid,
    required SystemMediaState smtc,
    required bool captureHealthy,
  }) {
    if (!transferOn || !splitActive) return false;
    if (!isFollowablePid(smtc)) return false;
    if (smtc.pid == routedPid) return false;
    return smtc.playing || !captureHealthy;
  }

  /// Wet HRTF stays silent until the source tree is pinned to muted speakers.
  /// No headphones/speakers split keeps overlay-preview (dry+wet on one device).
  static bool holdWetUntilPinned({required bool splitDetected}) => splitDetected;

  /// Process loopback of a paused SMTC session is silent frames, then a
  /// misleading "Wrong PID" native error.
  static String? refuseStartReason(SystemMediaState smtc) {
    if (!smtc.hasTrack) return '没有检测到系统正在播放的媒体';
    if (!smtc.playing) {
      final title = smtc.title.trim().isEmpty ? '系统媒体' : smtc.title.trim();
      return '请先播放 $title，再开 HRTF LIVE';
    }
    return null;
  }
}
