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
}
