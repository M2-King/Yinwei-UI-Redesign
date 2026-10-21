import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_sender_pacer.dart';

void main() {
  test('stall does not earn an unlimited burst of Opus packets', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(960, 48000), isTrue);
    pacer.tick(1000000);
    expect(pacer.take(960, 48000), isTrue);
    expect(pacer.take(960, 48000), isTrue);
    expect(pacer.take(960, 48000), isFalse);
  });

  test('15.6ms Windows timer supplies PCM at full rate', () {
    final pacer = ListenSenderPacer();
    var frames = 0;
    for (var now = 0; now < 10000000; now += 15600) {
      pacer.tick(now);
      while (pacer.take(512, 48000)) {
        frames += 512;
      }
    }
    expect(frames / 48000, greaterThan(10));
    expect(frames / 48000, lessThan(10.3));
  });

  test('migration resets old pacing debt and keeps startup bounded', () {
    final pacer = ListenSenderPacer()
      ..tick(0)
      ..tick(1000000);
    pacer.reset();
    expect(pacer.take(960, 48000), isTrue);
    expect(pacer.take(960, 48000), isFalse);
  });

  test('packet duration uses actual sample rate', () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(1920, 96000), isTrue);
    expect(pacer.take(1, 96000), isFalse);
  });

  test('low sample rate PCM does not get stuck above the usual burst budget',
      () {
    final pacer = ListenSenderPacer()..tick(0);
    expect(pacer.take(512, 8000), isFalse);
    pacer.tick(40000);
    pacer.tick(80000);
    expect(pacer.take(512, 8000), isTrue);
  });
}
