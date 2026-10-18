import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/remote_transform.dart';
import 'transform_test_support.dart';

void main() {
  Uint8List input(
          {int epoch = 7,
          int sequence = 1,
          int firstFrame = 0,
          bool discontinuous = false}) =>
      RemoteInputFrame.encode(
          epoch: epoch,
          sequence: sequence,
          firstFrame: firstFrame,
          pcm: syntheticInput(),
          discontinuous: discontinuous);

  test('YNI1 roundtrip preserves stereo PCM16 extremes within 2 KiB', () {
    final bytes = input();
    expect(bytes.length, 1968);
    expect(RemoteInputFrame.decode(bytes).pcm, syntheticInput());
    expect(RemoteInputFrame.decode(bytes).epoch, 7);
  });

  test('rejects truncated, oversized and malformed headers before ingress', () {
    for (final bytes in [
      input().sublist(1),
      [...input(), 0]
    ]) {
      expect(() => RemoteInputFrame.decode(bytes), throwsFormatException);
    }
    for (final offset in [0, 4, 32, 36, 40, 44]) {
      final bytes = input();
      ByteData.sublistView(bytes).setUint32(offset, 999, Endian.little);
      expect(() => RemoteInputFrame.decode(bytes), throwsFormatException);
    }
    for (final offset in [8, 16, 24]) {
      final bytes = input();
      ByteData.sublistView(bytes)
          .setUint64(offset, 0xffffffffffffffff, Endian.little);
      expect(() => RemoteInputFrame.decode(bytes), throwsFormatException);
    }
  });

  test('wrong epoch, replay, overlap and unmarked gap never reach adapter', () {
    final adapter = SyntheticTransformAdapter()..start(7);
    final flow = RemoteTransformFlow(7, adapter);
    flow.push(input());
    for (final bytes in [
      input(),
      input(epoch: 8, sequence: 2, firstFrame: 480),
      input(sequence: 2, firstFrame: 200),
      input(sequence: 3, firstFrame: 960)
    ]) {
      expect(() => flow.push(bytes), throwsFormatException);
    }
    expect(adapter.pushes, 1);
    expect(
        flow.push(input(sequence: 3, firstFrame: 960, discontinuous: true))[
            'accepted'],
        true);
    expect(adapter.gaps, [true, true]);
  });

  test('rate bucket allows one window of chunks then enforces 100/sec', () {
    var now = DateTime.utc(2026);
    final adapter = SyntheticTransformAdapter()..start(7);
    final flow = RemoteTransformFlow(7, adapter, now: () => now);
    const credit = RemoteTransformFlow.inputCredit;
    for (var i = 1; i <= credit; ++i) {
      flow.push(input(sequence: i, firstFrame: (i - 1) * 480));
    }
    expect(
        () => flow.push(input(sequence: credit + 1, firstFrame: credit * 480)),
        throwsFormatException);
    now = now.add(const Duration(milliseconds: 10));
    flow.push(input(sequence: credit + 1, firstFrame: credit * 480));
    expect(adapter.peakQueued, 8);
  });

  test('full adapter backlogs frames and drains them in order without gaps',
      () {
    var now = DateTime.utc(2026);
    final adapter = SyntheticTransformAdapter()..start(7);
    final flow = RemoteTransformFlow(7, adapter, now: () => now);
    for (var i = 1; i <= 12; ++i) {
      now = now.add(const Duration(milliseconds: 10));
      expect(
          flow.push(input(sequence: i, firstFrame: (i - 1) * 480))['accepted'],
          true);
    }
    expect(flow.accepted, 12);
    expect(flow.dropped, 0);
    expect(adapter.pushes, 8);
    for (var i = 0; i < 4; ++i) {
      adapter.read();
    }
    flow.drain();
    expect(adapter.pushes, 12);
    expect(adapter.gaps, [true, ...List.filled(11, false)]);
  });

  test('backlog overflow drops newest and marks next queued input as a gap',
      () {
    var now = DateTime.utc(2026);
    final adapter = SyntheticTransformAdapter()..start(7);
    final flow = RemoteTransformFlow(7, adapter, now: () => now);
    const held = 8 + RemoteTransformFlow.backlogFrames;
    for (var i = 1; i <= held + 1; ++i) {
      now = now.add(const Duration(milliseconds: 10));
      flow.push(input(sequence: i, firstFrame: (i - 1) * 480));
    }
    expect(flow.accepted, held);
    expect(flow.dropped, 1);
    while (adapter.queued > 0) {
      adapter.read();
      flow.drain();
    }
    now = now.add(const Duration(milliseconds: 10));
    final ack =
        flow.push(input(sequence: held + 2, firstFrame: (held + 1) * 480));
    expect(ack['resetOutput'], true);
    flow.drain();
    expect(adapter.gaps.last, true);
    adapter.stop();
    expect(adapter.queued, 0);
  });

  test('YNW1 output validates finite samples, epoch and ordered frame ranges',
      () {
    final adapter = SyntheticTransformAdapter()..start(7);
    adapter.tryPush(RemoteInputFrame.decode(input()), discontinuous: true);
    final packet = adapter.read()!;
    expect(RemoteOutputValidator(7).validate(packet), 1);
    final validator = RemoteOutputValidator(7)..validate(packet);
    expect(() => validator.validate(packet), throwsFormatException);
    expect(
        () => RemoteOutputValidator(8).validate(packet), throwsFormatException);
    ByteData.sublistView(packet).setFloat32(56, double.nan, Endian.little);
    expect(
        () => RemoteOutputValidator(7).validate(packet), throwsFormatException);
  });
}
