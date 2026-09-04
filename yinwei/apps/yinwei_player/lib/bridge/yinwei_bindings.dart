import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Low-level bindings to `spatial_core` C ABI (P2.4).
class YinweiBindings {
  YinweiBindings._(this._lib)
      : yinweiLastError = _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_last_error'),
        yinweiOpen = _lib.lookupFunction<_OpenNative, _OpenDart>('yinwei_open'),
        yinweiTrackTitle =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_title'),
        yinweiTrackArtist =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_artist'),
        yinweiTrackAlbum =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_album'),
        yinweiTrackPath = _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_path'),
        yinweiTrackDurationMs =
            _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_track_duration_ms'),
        yinweiTrackSampleRate =
            _lib.lookupFunction<_U32Native, _U32Dart>('yinwei_track_sample_rate'),
        yinweiSetParams =
            _lib.lookupFunction<_SetParamsNative, _SetParamsDart>('yinwei_set_params'),
        yinweiGetParams =
            _lib.lookupFunction<_GetParamsNative, _GetParamsDart>('yinwei_get_params'),
        yinweiApplyPreset =
            _lib.lookupFunction<_ApplyPresetNative, _ApplyPresetDart>('yinwei_apply_preset'),
        yinweiSetMode = _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_mode'),
        yinweiRebuildPreview =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_rebuild_preview'),
        yinweiPlay = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_play'),
        yinweiPause = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_pause'),
        yinweiSeekMs = _lib.lookupFunction<_SeekNative, _SeekDart>('yinwei_seek_ms'),
        yinweiPositionMs =
            _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_position_ms'),
        yinweiIsPlaying =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_is_playing'),
        yinweiCurrentAzimuthDeg =
            _lib.lookupFunction<_F32Native, _F32Dart>('yinwei_current_azimuth_deg'),
        yinweiExportWav =
            _lib.lookupFunction<_OpenNative, _OpenDart>('yinwei_export_wav'),
        yinweiDispose = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_dispose'),
        yinweiIsPreviewDirty =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_is_preview_dirty');

  final DynamicLibrary _lib;

  final _ErrDart yinweiLastError;
  final _OpenDart yinweiOpen;
  final _ErrDart yinweiTrackTitle;
  final _ErrDart yinweiTrackArtist;
  final _ErrDart yinweiTrackAlbum;
  final _ErrDart yinweiTrackPath;
  final _U64Dart yinweiTrackDurationMs;
  final _U32Dart yinweiTrackSampleRate;
  final _SetParamsDart yinweiSetParams;
  final _GetParamsDart yinweiGetParams;
  final _ApplyPresetDart yinweiApplyPreset;
  final _I32InDart yinweiSetMode;
  final _VoidDart yinweiRebuildPreview;
  final _VoidDart yinweiPlay;
  final _VoidDart yinweiPause;
  final _SeekDart yinweiSeekMs;
  final _U64Dart yinweiPositionMs;
  final _VoidDart yinweiIsPlaying;
  final _F32Dart yinweiCurrentAzimuthDeg;
  final _OpenDart yinweiExportWav;
  final _VoidDart yinweiDispose;
  final _VoidDart yinweiIsPreviewDirty;

  static YinweiBindings? _instance;
  static String? loadError;

  /// Try load `spatial_core` shared library. Returns null if unavailable.
  static YinweiBindings? tryLoad() {
    if (_instance != null) return _instance;
    try {
      final lib = _openLib();
      _instance = YinweiBindings._(lib);
      loadError = null;
      return _instance;
    } catch (e) {
      loadError = e.toString();
      return null;
    }
  }

  static DynamicLibrary _openLib() {
    if (Platform.isWindows) {
      for (final name in ['spatial_core.dll', 'libspatial_core.dll']) {
        try {
          return DynamicLibrary.open(name);
        } catch (_) {}
      }
      // Absolute fallback: next to the executable.
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;
      return DynamicLibrary.open('$dir\\spatial_core.dll');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libspatial_core.so');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libspatial_core.dylib');
    }
    throw UnsupportedError('Unsupported platform ${Platform.operatingSystem}');
  }

  String readLastError() {
    final buf = calloc<Uint8>(512);
    try {
      yinweiLastError(buf.cast<Char>(), 512);
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  String readCString(_ErrDart fn) {
    final buf = calloc<Uint8>(1024);
    try {
      final code = fn(buf.cast<Char>(), 1024);
      if (code != 0) return '';
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }
}

final class YinweiParamsC extends Struct {
  @Float()
  external double azimuthDeg;

  @Float()
  external double elevationDeg;

  @Float()
  external double distanceM;

  @Int32()
  external int motion;

  @Float()
  external double orbitHz;

  @Float()
  external double envelopment;

  @Float()
  external double reverbMix;

  @Int32()
  external int preset;
}

typedef _ErrNative = Int32 Function(Pointer<Char>, IntPtr);
typedef _ErrDart = int Function(Pointer<Char>, int);
typedef _OpenNative = Int32 Function(Pointer<Utf8>);
typedef _OpenDart = int Function(Pointer<Utf8>);
typedef _U64Native = Uint64 Function();
typedef _U64Dart = int Function();
typedef _U32Native = Uint32 Function();
typedef _U32Dart = int Function();
typedef _VoidNative = Int32 Function();
typedef _VoidDart = int Function();
typedef _I32InNative = Int32 Function(Int32);
typedef _I32InDart = int Function(int);
typedef _SeekNative = Int32 Function(Uint64);
typedef _SeekDart = int Function(int);
typedef _F32Native = Float Function();
typedef _F32Dart = double Function();
typedef _SetParamsNative = Int32 Function(Pointer<YinweiParamsC>);
typedef _SetParamsDart = int Function(Pointer<YinweiParamsC>);
typedef _GetParamsNative = Int32 Function(Pointer<YinweiParamsC>);
typedef _GetParamsDart = int Function(Pointer<YinweiParamsC>);
typedef _ApplyPresetNative = Int32 Function(Int32, Pointer<YinweiParamsC>);
typedef _ApplyPresetDart = int Function(int, Pointer<YinweiParamsC>);
