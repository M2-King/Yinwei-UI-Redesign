import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:yinwei_player/remote/listen_quality.dart';
import 'package:yinwei_player/remote/native_output_tap.dart';

export 'package:yinwei_player/remote/listen_quality.dart';

abstract class ListenOpusEncoder {
  bool setBitrate(int bitrate);

  /// Encodes [listenOpusFrames] interleaved stereo frames; null on failure.
  Uint8List? encode(Float32List pcm);
  void reset();
  void close();
}

/// libopus from `yinwei_opus.dll` (crates/yinwei_opus) next to the exe.
class NativeListenOpusEncoder implements ListenOpusEncoder {
  NativeListenOpusEncoder._(this._api, this._handle);
  final _OpusApi _api;
  final Pointer<Void> _handle;
  final Pointer<Float> _pcm = calloc<Float>(listenOpusFrames * 2);
  final Pointer<Uint8> _out = calloc<Uint8>(1500);
  bool _closed = false;

  static _OpusApi? _loaded;
  static bool _tried = false;

  /// Null when the DLL is missing or older: the stream stays uncompressed.
  /// [libraryPath] is for tests; the app loads the DLL next to its exe.
  static NativeListenOpusEncoder? tryCreate(
      {int bitrate = 320000, String? libraryPath}) {
    if (!Platform.isWindows) return null;
    if (!_tried) {
      _tried = true;
      try {
        final dir = File(Platform.resolvedExecutable).parent.path;
        _loaded = _OpusApi(DynamicLibrary.open(
            libraryPath ?? '$dir${Platform.pathSeparator}yinwei_opus.dll'));
        if (_loaded!.version() != 1) _loaded = null;
      } catch (_) {
        _loaded = null;
      }
    }
    final api = _loaded;
    if (api == null) return null;
    final handle = api.create(bitrate);
    return handle == nullptr ? null : NativeListenOpusEncoder._(api, handle);
  }

  @override
  bool setBitrate(int bitrate) =>
      !_closed && _api.setBitrate(_handle, bitrate) == 0;

  @override
  Uint8List? encode(Float32List pcm) {
    if (_closed || pcm.length != listenOpusFrames * 2) return null;
    _pcm.asTypedList(listenOpusFrames * 2).setAll(0, pcm);
    final n = _api.encode(_handle, _pcm, listenOpusFrames, _out, 1500);
    return n > 0 ? Uint8List.fromList(_out.asTypedList(n)) : null;
  }

  @override
  void reset() {
    if (!_closed) _api.reset(_handle);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _api.free(_handle);
    calloc.free(_pcm);
    calloc.free(_out);
  }
}

class _OpusApi {
  _OpusApi(DynamicLibrary lib)
      : version = lib.lookupFunction<Uint32 Function(), int Function()>(
            'yinwei_opus_version'),
        create = lib.lookupFunction<Pointer<Void> Function(Int32),
            Pointer<Void> Function(int)>('yinwei_opus_encoder_new'),
        setBitrate = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)>('yinwei_opus_encoder_set_bitrate'),
        encode = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>, Pointer<Float>, Uint32, Pointer<Uint8>, Uint32),
            int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Uint8>,
                int)>('yinwei_opus_encode'),
        reset = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('yinwei_opus_encoder_reset'),
        free = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('yinwei_opus_encoder_free');
  final int Function() version;
  final Pointer<Void> Function(int) create;
  final int Function(Pointer<Void>, int) setBitrate;
  final int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Uint8>, int)
      encode;
  final int Function(Pointer<Void>) reset;
  final void Function(Pointer<Void>) free;
}

/// The audio socket's packets for a client that chose a quality: YNW1 PCM
/// from the tap passed through (lossless, or any rate but 48 kHz), or
/// regrouped into 20 ms Opus packets (YNO1). Its own sequence numbers keep
/// acknowledgements continuous across quality changes. Clients that never
/// ask for a quality are served by the tap directly, exactly as before.
class ListenStreamSource implements RemoteOutputSource {
  ListenStreamSource(this.inner,
      {ListenOpusEncoder? encoder, ListenQuality quality = ListenQuality.high})
      : _encoder = encoder,
        _quality = quality {
    if (quality != ListenQuality.lossless) _encoder?.setBitrate(quality.bitrate);
  }

  final RemoteOutputSource inner;
  final ListenOpusEncoder? _encoder;
  ListenQuality _quality;
  int _sequence = 0;
  final _pcm = Float32List(listenOpusFrames * 2 * 2);
  int _have = 0, _firstFrame = 0;
  int? _epoch;

  bool get opusAvailable => _encoder != null;

  /// What is actually sent: lossless when no encoder is available.
  ListenQuality get quality => _encoder == null ? ListenQuality.lossless : _quality;

  set quality(ListenQuality value) {
    if (value == _quality) return;
    _quality = value;
    _have = 0;
    _epoch = null; // the encoder starts fresh on the next packet
    if (value != ListenQuality.lossless) {
      _encoder?.setBitrate(value.bitrate);
    }
  }

  @override
  void setEnabled(bool enabled) => inner.setEnabled(enabled);

  @override
  Uint8List? read() {
    while (true) {
      final packet = inner.read();
      if (packet == null) return null;
      final data = ByteData.sublistView(packet);
      final epoch = data.getUint64(8, Endian.little);
      final rate = data.getUint32(32, Endian.little);
      final frames = data.getUint32(36, Endian.little);
      final encoder = _encoder;
      if (encoder == null || _quality == ListenQuality.lossless || rate != 48000) {
        _have = 0;
        data.setUint64(16, ++_sequence, Endian.little);
        return packet;
      }
      if (epoch != _epoch) {
        // A new stream (seek, new track, source change): start a fresh frame.
        _epoch = epoch;
        _have = 0;
        encoder.reset();
      }
      if (_have == 0) _firstFrame = data.getUint64(24, Endian.little);
      for (var i = 0; i < frames * 2; ++i) {
        _pcm[_have * 2 + i] = data.getFloat32(56 + i * 4, Endian.little);
      }
      _have += frames;
      if (_have < listenOpusFrames) continue;
      final opus = encoder
          .encode(Float32List.sublistView(_pcm, 0, listenOpusFrames * 2));
      final firstFrame = _firstFrame;
      _have -= listenOpusFrames;
      _pcm.setRange(0, _have * 2, _pcm, listenOpusFrames * 2);
      _firstFrame += listenOpusFrames;
      if (opus == null) continue; // never expected; the next frame carries on
      final out = Uint8List(56 + opus.length);
      final header = ByteData.sublistView(out);
      header.setUint32(0, ynoMagic, Endian.little);
      header.setUint32(4, 1, Endian.little);
      header.setUint64(8, epoch, Endian.little);
      header.setUint64(16, ++_sequence, Endian.little);
      header.setUint64(24, firstFrame, Endian.little);
      header.setUint32(32, 48000, Endian.little);
      header.setUint32(36, listenOpusFrames, Endian.little);
      out.setRange(40, 56, packet, 40); // mode, dropped chunks, azimuth, elevation
      out.setRange(56, out.length, opus);
      return out;
    }
  }

  /// Closes the encoder only: the gateway owns the tap.
  @override
  void close() => _encoder?.close();
}
