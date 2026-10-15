import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'native_output_tap.dart';
import 'remote_transform.dart';

/// Optional ABI on the exact laptop DLL already owned by NativeEngine.
/// No iPad DSP or second engine state. Snapshots the native laptop config at
/// start; a local source/configuration change closes this session safely.
class NativeRemoteTransform implements RemoteTransformAdapter {
  NativeRemoteTransform._(this._start, this._push, this._read, this._stop,
      this.sourceAvailable, this.configuration);
  final int Function(int) _start;
  final int Function(Pointer<Int16>, int, int, int, int) _push;
  final int Function(Pointer<Float>, int, Pointer<OutputTapMetaC>) _read;
  final void Function() _stop;
  final bool Function() sourceAvailable;
  final String Function() configuration;
  final _pcm = calloc<Int16>(960);
  final _wet = calloc<Float>(1024);
  final _meta = calloc<OutputTapMetaC>();
  int _epoch = 0;
  bool _closed = false;
  String? _configuration;
  bool get running => _epoch != 0;

  static NativeRemoteTransform? tryCreate(
      {String? libraryPath,
      required bool Function() sourceAvailable,
      required String Function() configuration}) {
    final path = libraryPath ?? YinweiBindings.resolvedLibraryPath;
    if (path == null || sizeOf<OutputTapMetaC>() != 48) return null;
    try {
      final lib = DynamicLibrary.open(path);
      final version = lib.lookupFunction<Uint32 Function(), int Function()>(
          'yinwei_remote_ingress_version');
      if (version() != 1) return null;
      return NativeRemoteTransform._(
          lib.lookupFunction<Int32 Function(Uint64), int Function(int)>(
              'yinwei_remote_ingress_start'),
          lib.lookupFunction<
              Int32 Function(Pointer<Int16>, Uint32, Uint64, Uint64, Int32),
              int Function(Pointer<Int16>, int, int, int,
                  int)>('yinwei_remote_ingress_push'),
          lib.lookupFunction<
              Int32 Function(Pointer<Float>, Uint32, Pointer<OutputTapMetaC>),
              int Function(Pointer<Float>, int,
                  Pointer<OutputTapMetaC>)>('yinwei_remote_ingress_read'),
          lib.lookupFunction<Void Function(), void Function()>(
              'yinwei_remote_ingress_stop'),
          sourceAvailable,
          configuration);
    } catch (_) {
      return null;
    }
  }

  @override
  bool get available =>
      !_closed &&
      sourceAvailable() &&
      (!running || _configuration == configuration());

  @override
  void start(int epoch) {
    if (!available || running) throw StateError('Local source busy');
    _configuration = configuration();
    if (_start(epoch) != 0) {
      _configuration = null;
      throw StateError('Remote DSP start failed');
    }
    _epoch = epoch;
  }

  @override
  bool tryPush(RemoteInputFrame frame, {required bool discontinuous}) {
    if (!running || !available || frame.epoch != _epoch) {
      throw StateError('Remote source changed');
    }
    final data = ByteData.sublistView(frame.bytes);
    for (var i = 0; i < 960; ++i) {
      _pcm[i] =
          data.getInt16(RemoteInputFrame.headerBytes + i * 2, Endian.little);
    }
    final result =
        _push(_pcm, 960, _epoch, frame.firstFrame, discontinuous ? 1 : 0);
    if (result < 0) throw StateError('Remote ingress failed');
    return result == 1;
  }

  @override
  Uint8List? read() {
    if (!running) return null;
    if (!available) throw StateError('Local source changed');
    final frames = _read(_wet, 512, _meta);
    if (frames < 0) throw StateError('Remote output failed');
    if (frames == 0) return null;
    if (frames > 512 ||
        _meta.ref.frameCount != frames ||
        _meta.ref.epoch != _epoch) {
      throw StateError('Invalid remote output metadata');
    }
    for (var i = 0; i < frames * 2; ++i) {
      if (!_wet[i].isFinite) throw StateError('Nonfinite remote DSP output');
    }
    return NativeOutputTap.encodePacket(_wet, _meta.ref, frames);
  }

  @override
  void stop() {
    if (!running) return;
    _epoch = 0;
    _configuration = null;
    _stop();
  }

  @override
  void close() {
    if (_closed) return;
    stop();
    _closed = true;
    calloc.free(_pcm);
    calloc.free(_wet);
    calloc.free(_meta);
  }
}
