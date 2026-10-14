import 'dart:math' as math;
import 'dart:typed_data';
import 'package:yinwei_player/remote/native_output_tap.dart';

/// Quiet synthetic PCM for protocol/UI tests, never a native-engine substitute.
class FakeOutputSource implements RemoteOutputSource {
  bool enabled = false;
  int epoch = 0, sequence = 0, frame = 0;
  DateTime? _next;
  @override
  void setEnabled(bool value) {
    enabled = value;
    epoch++;
    frame = 0;
    _next = DateTime.now();
  }

  @override
  Uint8List? read() {
    final now = DateTime.now();
    if (!enabled || now.isBefore(_next!)) return null;
    _next = now.add(const Duration(microseconds: 10667));
    final packet = Uint8List(56 + 512 * 8);
    final data = ByteData.sublistView(packet);
    data.setUint32(0, 0x31574e59, Endian.little);
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, epoch, Endian.little);
    data.setUint64(16, ++sequence, Endian.little);
    data.setUint64(24, frame, Endian.little);
    data.setUint32(32, 48000, Endian.little);
    data.setUint32(36, 512, Endian.little);
    for (var i = 0; i < 512; i++) {
      final value = math.sin((frame + i) * 2 * math.pi * 440 / 48000) * 0.003;
      data.setFloat32(56 + i * 8, value, Endian.little);
      data.setFloat32(60 + i * 8, value, Endian.little);
    }
    frame += 512;
    return packet;
  }

  @override
  void close() => setEnabled(false);
}
