import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_sender_pacer.dart';

/// The gateway loop: a 10 ms timer that may stall, up to 4 packets per tick,
/// reading from a native tap that holds at most 8 chunks and drops the oldest.
({int dropped, int sent, double maxAheadMs}) simulate(
    {required int seconds, required bool Function(int tickUs) stalled}) {
  final pacer = ListenSenderPacer();
  const chunkUs = 10667; // 512 frames at 48 kHz
  var produced = 0, tap = 0, dropped = 0, sent = 0;
  var maxAhead = 0.0;
  for (var now = 0; now < seconds * 1000000; now += 1000) {
    while ((produced + 1) * chunkUs <= now) {
      produced++;
      if (tap == 8) {
        dropped++;
      } else {
        tap++;
      }
    }
    if (now % 10000 != 0 || stalled(now)) continue;
    pacer.tick(now);
    for (var i = 0; i < 4 && tap > 0; ++i) {
      if (!pacer.take(512, 48000)) break;
      tap--;
      sent++;
    }
    final ahead = sent * 10.667 - now / 1000;
    if (ahead > maxAhead) maxAhead = ahead;
  }
  return (dropped: dropped, sent: sent, maxAheadMs: maxAhead);
}

void main() {
  test('repeated sender stalls within the tap size never drop audio', () {
    // 40/50 ms stalls every 300 ms: the old 1.02x pacer dropped 34/68 chunks
    // in 10 s. Stalls longer than the tap's ~85 ms lose audio by physics.
    for (final stallMs in [40, 50]) {
      final run = simulate(
          seconds: 10, stalled: (us) => us % 300000 < stallMs * 1000);
      expect(run.dropped, 0, reason: '$stallMs ms stalls');
    }
  });

  test('a single 50 ms stall drains at once, without loss', () {
    final run = simulate(
        seconds: 3, stalled: (us) => us >= 1000000 && us < 1050000);
    expect(run.dropped, 0);
  });

  test('steady 10 ms timer sends in real time and never runs far ahead', () {
    final run = simulate(seconds: 10, stalled: (_) => false);
    expect(run.dropped, 0);
    expect(run.maxAheadMs, lessThanOrEqualTo(ListenSenderPacer.leadMs + 11));
  });

  test('a faster-than-real-time source is held to real time plus the lead', () {
    final pacer = ListenSenderPacer();
    var frames = 0;
    for (var now = 0; now < 10000000; now += 15600) {
      pacer.tick(now);
      while (pacer.take(512, 48000)) {
        frames += 512;
      }
    }
    expect(frames / 48000, greaterThan(10));
    expect(frames / 48000, lessThan(10.1));
  });

  test('a long pause does not earn an unbounded burst', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(960, 48000), isTrue);
    pacer.tick(5000000); // the source was silent for 5 s
    var packets = 0;
    while (pacer.take(960, 48000)) {
      packets++;
    }
    const allowanceMs =
        ListenSenderPacer.maxBehindMs + ListenSenderPacer.leadMs;
    expect(packets * 20, lessThanOrEqualTo(allowanceMs));
  });

  test('reset starts again with only the lead allowed', () {
    final pacer = ListenSenderPacer()
      ..tick(0)
      ..tick(1000000);
    pacer.reset();
    expect(pacer.take(960, 48000), isTrue);
    expect(pacer.take(960, 48000), isTrue);
    expect(pacer.take(960, 48000), isFalse);
  });

  test('packet duration uses the actual sample rate', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(1920, 96000), isTrue); // 20 ms
    expect(pacer.take(1920, 96000), isTrue); // 40 ms = the lead
    expect(pacer.take(1, 96000), isFalse);
  });

  test('one low-sample-rate packet longer than the lead still goes out', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(512, 8000), isTrue); // 64 ms
    expect(pacer.take(512, 8000), isFalse);
    pacer.tick(80000);
    expect(pacer.take(512, 8000), isTrue);
  });

  test('invalid input is refused', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(0, 48000), isFalse);
    expect(pacer.take(512, 0), isFalse);
  });
}
