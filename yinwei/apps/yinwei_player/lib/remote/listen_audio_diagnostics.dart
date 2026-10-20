import 'dart:collection';
import 'dart:math' as math;

/// Metadata only: no PCM, credentials, media titles or remote addresses.
/// Arrival times are taken at the Dart WebSocket boundary with a monotonic clock.
class ListenAudioDiagnostics {
  static const windowSize = 1024;
  final _arrival = ListQueue<double>();
  final _jitter = ListQueue<double>();
  final _writes = ListQueue<double>();
  final _history = ListQueue<Map<String, Object?>>();
  int? _epoch, _sequence, _nextFrame, _sourceDrops, _arrivalUs;
  double _previousDurationMs = 0;
  int missingPackets = 0, missingFrames = 0, reorderedOrDuplicate = 0;
  int sourceDrops = 0, streamChanges = 0, invalidPackets = 0;
  int writeLimitDrops = 0, interruptedDrops = 0, nativeRejected = 0;
  double maxArrivalMs = 0, maxJitterMs = 0, maxWriteMs = 0;

  /// A reconnect/source switch can introduce a different tap with lower epoch
  /// and sequence numbers. Never compare that tap against the old connection.
  void connectionOpened() {
    _epoch = _sequence = _nextFrame = _sourceDrops = _arrivalUs = null;
  }

  void record({
    required int epoch,
    required int sequence,
    required int firstFrame,
    required int frames,
    required int sampleRate,
    required int droppedChunks,
    required int nowUs,
  }) {
    if (_epoch != null &&
        (epoch < _epoch! || (epoch == _epoch && sequence <= _sequence!))) {
      reorderedOrDuplicate++;
      return;
    }
    final sameStream = epoch == _epoch;
    if (sameStream) {
      missingPackets += math.max(0, sequence - _sequence! - 1);
      missingFrames += math.max(0, firstFrame - _nextFrame!);
      final interval = math.max(0, nowUs - _arrivalUs!) / 1000;
      _add(_arrival, interval);
      maxArrivalMs = math.max(maxArrivalMs, interval);
      // Only continuous source frames define a meaningful packet-duration
      // reference. Arrival intervals still include source pauses/discontinuities.
      if (firstFrame == _nextFrame) {
        final jitter = (interval - _previousDurationMs).abs();
        _add(_jitter, jitter);
        maxJitterMs = math.max(maxJitterMs, jitter);
      }
    } else if (_epoch != null) {
      streamChanges++;
    }
    // The native tap's drop count can survive epoch changes. First observation
    // is a baseline, never charge historical drops to this listening session.
    if (_sourceDrops != null && droppedChunks >= _sourceDrops!) {
      sourceDrops += droppedChunks - _sourceDrops!;
    }
    _epoch = epoch;
    _sequence = sequence;
    _nextFrame = firstFrame + frames;
    _sourceDrops = droppedChunks;
    _arrivalUs = nowUs;
    _previousDurationMs = frames * 1000 / sampleRate;
  }

  void writeCompleted(int elapsedUs) {
    final ms = elapsedUs / 1000;
    _add(_writes, ms);
    maxWriteMs = math.max(maxWriteMs, ms);
  }

  void sampleBuffer(
      {required int nowUs,
      required int queuedMs,
      required int targetMs,
      required int underruns,
      required int dropped}) {
    if (_history.length == 120) _history.removeFirst();
    _history.add({
      'elapsedMs': nowUs ~/ 1000,
      'queuedMs': queuedMs,
      'targetMs': targetMs,
      'underruns': underruns,
      'dropped': dropped
    });
  }

  void _add(ListQueue<double> values, double value) {
    if (values.length == windowSize) values.removeFirst();
    values.add(value);
  }

  Map<String, Object?> _summary(ListQueue<double> values, double lifetimeMax) {
    final sorted = values.toList()..sort();
    double? percentile(double p) =>
        sorted.isEmpty ? null : sorted[(sorted.length * p).ceil() - 1];
    return {
      'samples': sorted.length,
      'p50Ms': percentile(0.5),
      'p95Ms': percentile(0.95),
      'maxMs': sorted.isEmpty ? null : sorted.last,
      'sessionMaxMs': values.isEmpty ? null : lifetimeMax
    };
  }

  Map<String, Object?> snapshot() => {
        'arrival': _summary(_arrival, maxArrivalMs),
        'absoluteInterarrivalJitter': _summary(_jitter, maxJitterMs),
        'nativeWriteRoundTrip': _summary(_writes, maxWriteMs),
        'missingPackets': missingPackets,
        'missingFrames': missingFrames,
        'reorderedOrDuplicate': reorderedOrDuplicate,
        'sourceDroppedChunks': sourceDrops,
        'streamChanges': streamChanges,
        'invalidPackets': invalidPackets,
        'writeLimitDrops': writeLimitDrops,
        'interruptedDrops': interruptedDrops,
        'nativeRejected': nativeRejected,
        'bufferHistory':
            _history.map((point) => Map<String, Object?>.of(point)).toList(),
      };
}
