import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_audio_diagnostics.dart';

void main() {
  void packet(ListenAudioDiagnostics d, int seq, int timeUs,
          {int epoch = 1, int? firstFrame, int drops = 0}) =>
      d.record(
          epoch: epoch,
          sequence: seq,
          firstFrame: firstFrame ?? (seq - 1) * 480,
          frames: 480,
          sampleRate: 48000,
          droppedChunks: drops,
          nowUs: timeUs);

  test('measures arrivals and absolute jitter with no invented empty values',
      () {
    final d = ListenAudioDiagnostics();
    expect((d.snapshot()['arrival'] as Map)['p50Ms'], isNull);
    packet(d, 1, 0);
    packet(d, 2, 10000);
    packet(d, 3, 30000);
    packet(d, 4, 33000);
    final s = d.snapshot();
    expect(s['arrival'], {
      'samples': 3,
      'p50Ms': 10.0,
      'p95Ms': 20.0,
      'maxMs': 20.0,
      'sessionMaxMs': 20.0
    });
    expect((s['absoluteInterarrivalJitter'] as Map)['p50Ms'], 7.0);
    expect((s['absoluteInterarrivalJitter'] as Map)['p95Ms'], 10.0);
  });

  test(
      'classifies source losses, sequence gaps and repeats without double counting',
      () {
    final d = ListenAudioDiagnostics();
    packet(d, 1, 0, drops: 100);
    packet(d, 3, 20000, drops: 101);
    packet(d, 2, 21000, drops: 100);
    packet(d, 3, 22000, drops: 101);
    // A lock-contention drop may skip frames without skipping a sequence.
    packet(d, 4, 40000, firstFrame: 1920, drops: 102);
    final s = d.snapshot();
    expect(s['missingPackets'], 1);
    expect(s['missingFrames'], 960);
    expect(s['reorderedOrDuplicate'], 2);
    expect(s['sourceDroppedChunks'], 2);
    expect((s['absoluteInterarrivalJitter'] as Map)['samples'], 0);
  });

  test('epochs and new connections cannot produce bogus huge gaps', () {
    final d = ListenAudioDiagnostics();
    packet(d, 900, 0, epoch: 9, drops: 12);
    packet(d, 901, 10000, epoch: 10, firstFrame: 0, drops: 12);
    d.connectionOpened();
    packet(d, 1, 2000000, drops: 300);
    packet(d, 2, 2010000, drops: 301);
    final s = d.snapshot();
    expect(s['missingFrames'], 0);
    expect(s['missingPackets'], 0);
    expect(s['reorderedOrDuplicate'], 0);
    expect(s['sourceDroppedChunks'], 1);
    expect((s['arrival'] as Map)['samples'], 1);
  });

  test(
      'diagnostic storage stays bounded during long sessions and exports copies',
      () {
    final d = ListenAudioDiagnostics();
    for (var i = 1; i <= 3000; ++i) {
      packet(d, i, i * 10000);
      d.writeCompleted(2000);
      d.sampleBuffer(
          nowUs: i * 500000,
          queuedMs: 120,
          targetMs: 170,
          underruns: 1,
          dropped: 0);
    }
    final s = d.snapshot();
    expect((s['arrival'] as Map)['samples'], 1024);
    expect((s['nativeWriteRoundTrip'] as Map)['p95Ms'], 2.0);
    final history = s['bufferHistory'] as List;
    expect(history.length, 120);
    (history.first as Map)['queuedMs'] = -1;
    expect(((d.snapshot()['bufferHistory'] as List).first as Map)['queuedMs'],
        120);
  });
}
