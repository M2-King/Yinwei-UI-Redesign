import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_stream_source.dart';
import 'package:yinwei_player/remote/native_output_tap.dart';

/// YNW1 packets on demand, 512 frames each, like the native tap.
class _Tap implements RemoteOutputSource {
  int epoch = 1, sequence = 100, frame = 0, rate = 48000;
  int available = 0;
  @override
  void setEnabled(bool enabled) {}
  @override
  Uint8List? read() {
    if (available == 0) return null;
    --available;
    final packet = Uint8List(56 + 512 * 8);
    final data = ByteData.sublistView(packet);
    data.setUint32(0, ynwMagic, Endian.little);
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, epoch, Endian.little);
    data.setUint64(16, ++sequence, Endian.little);
    data.setUint64(24, frame, Endian.little);
    data.setUint32(32, rate, Endian.little);
    data.setUint32(36, 512, Endian.little);
    data.setUint32(40, 3, Endian.little); // mode
    data.setUint32(44, 7, Endian.little); // dropped chunks
    data.setFloat32(48, 42.5, Endian.little);
    for (var i = 0; i < 512; ++i) {
      final v = math.sin((frame + i) * 2 * math.pi * 440 / 48000) * 0.3;
      data.setFloat32(56 + i * 8, v, Endian.little);
      data.setFloat32(60 + i * 8, -v, Endian.little);
    }
    frame += 512;
    return packet;
  }

  @override
  void close() {}
}

class _Encoder implements ListenOpusEncoder {
  final frames = <Float32List>[];
  int bitrate = 0, resets = 0;
  bool closed = false;
  @override
  bool setBitrate(int value) {
    bitrate = value;
    return true;
  }

  @override
  Uint8List? encode(Float32List pcm) {
    frames.add(Float32List.fromList(pcm));
    return Uint8List.fromList([frames.length, 1, 2, 3]);
  }

  @override
  void reset() => ++resets;
  @override
  void close() => closed = true;
}

ByteData _header(Uint8List packet) => ByteData.sublistView(packet);

void main() {
  test('groups 512-frame PCM into 20 ms Opus packets, keeping the timeline',
      () {
    final tap = _Tap()..available = 15; // 7680 frames = 8 Opus frames
    final encoder = _Encoder();
    final source = ListenStreamSource(tap, encoder: encoder);
    expect(encoder.bitrate, 320000);
    final packets = <Uint8List>[];
    for (Uint8List? p; (p = source.read()) != null;) {
      packets.add(p!);
    }
    expect(packets, hasLength(8));
    for (var i = 0; i < 8; ++i) {
      final h = _header(packets[i]);
      expect(h.getUint32(0, Endian.little), ynoMagic);
      expect(h.getUint32(4, Endian.little), 1);
      expect(h.getUint64(8, Endian.little), 1);
      expect(h.getUint64(16, Endian.little), i + 1);
      expect(h.getUint64(24, Endian.little), i * 960);
      expect(h.getUint32(32, Endian.little), 48000);
      expect(h.getUint32(36, Endian.little), 960);
      expect(h.getUint32(40, Endian.little), 3);
      expect(h.getUint32(44, Endian.little), 7);
      expect(h.getFloat32(48, Endian.little), 42.5);
      expect(packets[i].sublist(56), [i + 1, 1, 2, 3]);
    }
    // The encoder saw the tap's samples in order, no gaps or repeats.
    final all = encoder.frames.expand((f) => f).toList();
    for (final frame in [0, 511, 512, 959, 960, 4000, 7679]) {
      final v = math.sin(frame * 2 * math.pi * 440 / 48000) * 0.3;
      expect(all[frame * 2], closeTo(v, 1e-6));
      expect(all[frame * 2 + 1], closeTo(-v, 1e-6));
    }
  });

  test('lossless passes PCM through with continuous sequence numbers', () {
    final tap = _Tap()..available = 1;
    final encoder = _Encoder();
    final source = ListenStreamSource(tap, encoder: encoder);
    expect(source.read(), isNull); // only 512 frames buffered
    tap.available = 1;
    final opus = source.read()!;
    expect(_header(opus).getUint64(16, Endian.little), 1);
    source.quality = ListenQuality.lossless;
    tap.available = 1;
    final pcm = source.read()!;
    expect(_header(pcm).getUint32(0, Endian.little), ynwMagic);
    expect(_header(pcm).getUint64(16, Endian.little), 2);
    expect(pcm.length, 56 + 512 * 8);
    source.quality = ListenQuality.max;
    expect(encoder.bitrate, 510000);
    tap.available = 2;
    final next = source.read()!;
    expect(_header(next).getUint32(0, Endian.little), ynoMagic);
    expect(_header(next).getUint64(16, Endian.little), 3);
    // A fresh frame after the switch: the encoder was reset.
    expect(encoder.resets, 2);
  });

  test('other sample rates and a missing encoder stay uncompressed', () {
    final tap = _Tap()
      ..rate = 44100
      ..available = 2;
    final source = ListenStreamSource(tap, encoder: _Encoder());
    expect(_header(source.read()!).getUint32(0, Endian.little), ynwMagic);
    final plain = ListenStreamSource(_Tap()..available = 1);
    expect(plain.opusAvailable, isFalse);
    expect(plain.quality, ListenQuality.lossless);
    expect(_header(plain.read()!).getUint32(0, Endian.little), ynwMagic);
  });

  test('a new stream starts a fresh Opus frame', () {
    final tap = _Tap()..available = 1;
    final encoder = _Encoder();
    final source = ListenStreamSource(tap, encoder: encoder);
    expect(source.read(), isNull); // 512 frames waiting
    tap
      ..epoch = 2
      ..frame = 50000
      ..available = 2;
    final packet = source.read()!;
    expect(_header(packet).getUint64(8, Endian.little), 2);
    expect(_header(packet).getUint64(24, Endian.little), 50000);
    expect(encoder.resets, 2);
    source.close();
    expect(encoder.closed, isTrue);
  });

  test('quality names parse strictly', () {
    expect(ListenQuality.parse('high'), ListenQuality.high);
    expect(ListenQuality.parse('max'), ListenQuality.max);
    expect(ListenQuality.parse('lossless'), ListenQuality.lossless);
    expect(ListenQuality.parse('ultra'), isNull);
    expect(ListenQuality.parse(1), isNull);
  });

  test('the bundled Windows encoder makes real Opus packets', () {
    final dll = File('windows/runner/yinwei_opus.dll');
    final encoder = NativeListenOpusEncoder.tryCreate(
        libraryPath: dll.absolute.path);
    expect(encoder, isNotNull);
    final pcm = Float32List(960 * 2);
    var bytes = 0;
    for (var f = 0; f < 50; ++f) {
      for (var i = 0; i < 960; ++i) {
        final v = math.sin((f * 960 + i) * 2 * math.pi * 440 / 48000) * 0.3;
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
      }
      final packet = encoder!.encode(pcm)!;
      expect(packet.length, inInclusiveRange(1, 1276)); // TOC byte + up to 1275
      bytes += packet.length;
    }
    // One second at 320 kbit/s: about 40 KB, far below 3.1 Mbit/s PCM.
    expect(bytes * 8, lessThan(400000));
    expect(encoder!.setBitrate(510000), isTrue);
    expect(encoder.setBitrate(5000000), isFalse);
    encoder.reset();
    encoder.close();
  }, skip: !Platform.isWindows);
}
