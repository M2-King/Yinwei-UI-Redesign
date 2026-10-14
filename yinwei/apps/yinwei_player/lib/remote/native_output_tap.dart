import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';

final class OutputTapMetaC extends Struct {
  @Uint64()
  external int epoch;
  @Uint64()
  external int sequence;
  @Uint64()
  external int firstFrame;
  @Uint32()
  external int sampleRate;
  @Uint32()
  external int frameCount;
  @Uint32()
  external int mode;
  @Uint32()
  external int droppedChunks;
  @Float()
  external double azimuthDeg;
  @Float()
  external double elevationDeg;
}

/// Optional additive ABI, loaded from the same absolute DLL already owned by
/// NativeEngine. Older binaries keep local playback and report unavailable.
abstract class RemoteOutputSource {
  void setEnabled(bool enabled);
  Uint8List? read();
  void close();
}

class NativeOutputTap implements RemoteOutputSource {
  NativeOutputTap._(this._enable, this._read);
  final int Function(int) _enable;
  final int Function(Pointer<Float>, int, Pointer<OutputTapMetaC>) _read;
  final Pointer<Float> _pcm = calloc<Float>(1024);
  final Pointer<OutputTapMetaC> _meta = calloc<OutputTapMetaC>();
  bool _closed = false;

  static NativeOutputTap? tryCreate({bool live = false}) {
    final path = YinweiBindings.resolvedLibraryPath;
    if (path == null || sizeOf<OutputTapMetaC>() != 48) return null;
    try {
      final lib = DynamicLibrary.open(path);
      final prefix = live ? 'yinwei_live_output_tap' : 'yinwei_output_tap';
      final version = lib.lookupFunction<Uint32 Function(), int Function()>(
          '${prefix}_version');
      if (version() != 1) return null;
      return NativeOutputTap._(
          lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
              '${prefix}_enable'),
          lib.lookupFunction<
              Int32 Function(Pointer<Float>, Uint32, Pointer<OutputTapMetaC>),
              int Function(Pointer<Float>, int,
                  Pointer<OutputTapMetaC>)>('${prefix}_read'));
    } catch (_) {
      return null;
    }
  }

  @override
  void setEnabled(bool enabled) {
    if (_closed || _enable(enabled ? 1 : 0) != 0) {
      throw StateError('Native output tap unavailable');
    }
  }

  /// Wire v1: 56-byte little-endian header followed by interleaved stereo f32.
  @override
  Uint8List? read() {
    if (_closed) return null;
    final frames = _read(_pcm, 512, _meta);
    if (frames < 0) throw StateError('Native output read failed');
    if (frames == 0) return null;
    final m = _meta.ref;
    if (frames > 512 ||
        m.frameCount != frames ||
        m.sampleRate < 8000 ||
        m.sampleRate > 192000) {
      throw StateError('Invalid native output packet');
    }
    final bytes = Uint8List(56 + frames * 8);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x31574e59, Endian.little); // YNW1
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, m.epoch, Endian.little);
    data.setUint64(16, m.sequence, Endian.little);
    data.setUint64(24, m.firstFrame, Endian.little);
    data.setUint32(32, m.sampleRate, Endian.little);
    data.setUint32(36, frames, Endian.little);
    data.setUint32(40, m.mode, Endian.little);
    data.setUint32(44, m.droppedChunks, Endian.little);
    data.setFloat32(48, m.azimuthDeg, Endian.little);
    data.setFloat32(52, m.elevationDeg, Endian.little);
    for (var i = 0; i < frames * 2; ++i) {
      final sample = _pcm[i];
      data.setFloat32(56 + i * 4, sample.isFinite ? sample : 0, Endian.little);
    }
    return bytes;
  }

  @override
  void close() {
    if (_closed) return;
    _enable(0);
    _closed = true;
    calloc.free(_pcm);
    calloc.free(_meta);
  }
}
