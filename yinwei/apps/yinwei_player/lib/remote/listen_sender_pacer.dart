/// Bounded media-time credit, not a packet-count rate limit. Windows timer
/// coalescing must still supply 512-frame PCM without unlimited catch-up bursts.
class ListenSenderPacer {
  int? _lastUs;
  double _creditMs = 20;
  double _capacityMs = 40;
  void reset() {
    _lastUs = null;
    _creditMs = 20;
    _capacityMs = 40;
  }

  void tick(int nowUs) {
    final previous = _lastUs;
    _lastUs = nowUs;
    if (previous != null) {
      // Small surplus allows the bounded native backlog to recover after stalls.
      _creditMs = (_creditMs + (nowUs - previous).clamp(0, 40000) / 1000 * 1.02)
          .clamp(0, _capacityMs)
          .toDouble();
    }
  }

  bool take(int frames, int sampleRate) {
    if (frames <= 0 || sampleRate <= 0) return false;
    final duration = frames * 1000 / sampleRate;
    if (duration > _capacityMs && duration <= 64) {
      _capacityMs = duration;
    }
    if (duration > _creditMs + 0.001) {
      return false;
    }
    _creditMs -= duration;
    return true;
  }
}
