/// Capture health for loopback HRTF — not a one-shot frame count.
///
/// Silent WASAPI packets are stored as zeros but still increment
/// [capturedFrames]. UI must not treat `capturedFrames >= 128` as wet audio.
class LiveCaptureHealth {
  const LiveCaptureHealth({
    required this.running,
    required this.capturedFrames,
    required this.energyFrames,
    required this.prevCapturedFrames,
    required this.prevEnergyFrames,
    this.lastEnergyAgeMs,
  });

  final bool running;
  final int capturedFrames;
  final int energyFrames;
  final int prevCapturedFrames;
  final int prevEnergyFrames;

  /// Age of last non-silent chunk, if known.
  final int? lastEnergyAgeMs;

  /// Quiet / next-track gaps are not a disconnect. 1.2s was flipping LIVE off
  /// in the middle of a song.
  static const recentEnergyMs = 5000;

  /// Healthy live: rising energy, or rising frames plus recent non-silent energy.
  bool get healthy {
    if (!running) return false;
    if (energyFrames > prevEnergyFrames) return true;
    final framesRising = capturedFrames > prevCapturedFrames;
    final recentEnergy = energyFrames > 0 &&
        lastEnergyAgeMs != null &&
        lastEnergyAgeMs! < recentEnergyMs;
    return framesRising && recentEnergy;
  }

  /// Compact bar / snackbar copy. Exclude-self silence is "nothing is
  /// rendering", not a Yinwei PID dump.
  static String explainStartFailure({
    required String? nativeError,
    required bool sourcePlaying,
    required String sourceTitle,
    required int sourcePid,
  }) {
    final title = sourceTitle.trim().isEmpty ? '系统媒体' : sourceTitle.trim();
    if (!sourcePlaying) {
      return '请先播放 $title，再开 HRTF LIVE';
    }
    final err = nativeError ?? '';
    if (err.contains('process loopback silent') ||
        err.contains('Wrong PID') ||
        err.contains('blocked capture')) {
      return '环回静音 · 无法捕获 $title（pid $sourcePid）。确认正在播放，且未静音源应用。';
    }
    return err.isEmpty ? 'Live HRTF 启动失败' : err;
  }
}
