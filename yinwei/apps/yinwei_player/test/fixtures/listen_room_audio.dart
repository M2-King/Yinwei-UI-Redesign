import 'dart:typed_data';

/// A tiny YNW1 stereo packet, with deliberate peaks in either channel.
Uint8List listenRoomPacket(List<double> samples) {
  assert(samples.isNotEmpty && samples.length.isEven);
  final packet = Uint8List(56 + samples.length * 4);
  final data = ByteData.sublistView(packet);
  data.setUint32(0, 0x31574e59, Endian.little);
  data.setUint32(4, 1, Endian.little);
  data.setUint64(8, 1, Endian.little);
  data.setUint64(16, 1, Endian.little);
  data.setUint32(32, 48000, Endian.little);
  data.setUint32(36, samples.length ~/ 2, Endian.little);
  for (var i = 0; i < samples.length; ++i) {
    data.setFloat32(56 + i * 4, samples[i], Endian.little);
  }
  return packet;
}
