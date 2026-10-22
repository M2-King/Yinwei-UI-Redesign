import 'dart:math' as math;

/// Keeps the Listen sender from running AHEAD of real time, never from
/// catching up.
///
/// Media is allowed out as long as the audio sent so far is no more than
/// [leadMs] ahead of the wall clock. Audio that is late (the sender timer or
/// the isolate stalled, so the native tap has a backlog) is released at once:
/// the tap only holds about 85 ms, so holding late audio back makes it drop.
/// A source that pauses and resumes must not earn an unbounded allowance, so
/// "behind" is capped at [maxBehindMs].
class ListenSenderPacer {
  static const leadMs = 40.0;
  static const maxBehindMs = 300.0;

  int? _originUs;
  int _nowUs = 0;
  double _sentMs = 0;

  void reset() {
    _originUs = null;
    _nowUs = 0;
    _sentMs = 0;
  }

  double get _wallMs =>
      _originUs == null ? 0 : (_nowUs - _originUs!) / 1000;

  void tick(int nowUs) {
    _originUs ??= nowUs;
    _nowUs = math.max(_nowUs, nowUs);
    final wall = _wallMs;
    if (wall - _sentMs > maxBehindMs) _sentMs = wall - maxBehindMs;
  }

  /// True when [frames] at [sampleRate] may be sent now (and counts them).
  bool take(int frames, int sampleRate) {
    if (frames <= 0 || sampleRate <= 0) return false;
    final duration = frames * 1000 / sampleRate;
    // A single packet longer than the lead (low sample rates) is still allowed.
    if (_sentMs + duration > _wallMs + math.max(leadMs, duration) + 0.001) {
      return false;
    }
    _sentMs += duration;
    return true;
  }
}
