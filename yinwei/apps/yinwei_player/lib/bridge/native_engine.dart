import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Real engine via `spatial_core` C ABI / `dart:ffi` (P2.4).
///
/// Heavy open/export may run in a background isolate, but that isolate **must**
/// load the same absolute DLL path as the main isolate. Otherwise Windows can
/// map two copies of `spatial_core.dll` → two GLOBAL sessions → live setParams
/// never reaches the playing audio (pause→play / dead drag symptoms).
class NativeEngine implements EngineApi {
  NativeEngine(this._b);

  final YinweiBindings _b;

  static NativeEngine? tryCreate() {
    final b = YinweiBindings.tryLoad();
    return b == null ? null : NativeEngine(b);
  }

  String get _libPath {
    final p = YinweiBindings.resolvedLibraryPath;
    if (p == null || p.isEmpty) {
      throw StateError('Native library path not resolved');
    }
    return p;
  }

  void _check(int code, {bool allowAudioDevice = false}) {
    if (code == 0) return;
    if (allowAudioDevice && code == 5) {
      throw StateError('AudioDevice: ${_b.readLastError()}');
    }
    final msg = _b.readLastError();
    switch (code) {
      case 1:
        throw StateError('FileNotFound: $msg');
      case 2:
        throw StateError('NoTrackLoaded: $msg');
      case 3:
        throw StateError('InvalidParam: $msg');
      case 4:
        throw StateError('Decode: $msg');
      case 5:
        throw StateError('AudioDevice: $msg');
      case 6:
        throw StateError('Io: $msg');
      default:
        throw StateError('NativeError($code): $msg');
    }
  }

  @override
  Future<TrackMeta> open(String path) async {
    final libPath = _libPath;
    final code = await Isolate.run(() {
      final b = YinweiBindings.loadFromPath(libPath);
      final p = path.toNativeUtf8();
      try {
        return b.yinweiOpen(p);
      } finally {
        malloc.free(p);
      }
    });
    _check(code);
    return TrackMeta(
      title: _b.readCString(_b.yinweiTrackTitle),
      artist: _b.readCString(_b.yinweiTrackArtist),
      album: _b.readCString(_b.yinweiTrackAlbum),
      duration: Duration(milliseconds: _b.yinweiTrackDurationMs()),
      path: _b.readCString(_b.yinweiTrackPath),
    );
  }

  @override
  Future<void> setParams(SpatialParams params) async {
    final ptr = calloc<YinweiParamsC>();
    try {
      _writeParams(ptr.ref, params);
      _check(_b.yinweiSetParams(ptr));
      try {
        _check(_b.setEq(params.eqDb));
      } catch (_) {
        // Older DLL without yinwei_set_eq.
      }
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<SpatialParams> applyPreset(PositionPreset preset) async {
    final ptr = calloc<YinweiParamsC>();
    try {
      _check(_b.yinweiApplyPreset(_presetIndex(preset), ptr));
      return _readParams(ptr.ref);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> setPlaybackMode(PlaybackMode mode) async {
    _check(_b.yinweiSetMode(mode == PlaybackMode.original ? 0 : 1));
  }

  @override
  Future<void> rebuildPreview({void Function(double progress)? onProgress}) async {
    onProgress?.call(0.05);
    final libPath = _libPath;
    final code = await Isolate.run(() {
      final b = YinweiBindings.loadFromPath(libPath);
      return b.yinweiRebuildPreview();
    });
    onProgress?.call(1.0);
    _check(code);
  }

  @override
  Future<void> play() async {
    // Stay on the main isolate binding — never reopen the DLL here.
    _check(_b.yinweiPlay(), allowAudioDevice: true);
  }

  @override
  Future<void> pause() async {
    _check(_b.yinweiPause());
  }

  @override
  Future<void> seek(Duration position) async {
    _check(_b.yinweiSeekMs(position.inMilliseconds));
  }

  @override
  Future<Duration> position() async {
    return Duration(milliseconds: _b.yinweiPositionMs());
  }

  @override
  Future<bool> isPlaying() async {
    return _b.yinweiIsPlaying() != 0;
  }

  @override
  Future<double> currentAzimuthDeg() async {
    return _b.yinweiCurrentAzimuthDeg();
  }

  @override
  Future<double> currentElevationDeg() async {
    return _b.yinweiCurrentElevationDeg();
  }

  @override
  Future<void> exportWav(
    String outPath, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);
    final libPath = _libPath;
    final code = await Isolate.run(() {
      final b = YinweiBindings.loadFromPath(libPath);
      final p = outPath.toNativeUtf8();
      try {
        return b.yinweiExportWav(p);
      } finally {
        malloc.free(p);
      }
    });
    onProgress?.call(1.0);
    _check(code);
  }

  @override
  Future<void> dispose() async {
    _check(_b.yinweiDispose());
  }

  @override
  Future<bool> isPreviewDirty() async {
    return _b.yinweiIsPreviewDirty() != 0;
  }

  @override
  bool get supportsArray => _b.hasArray;

  @override
  bool get supportsExtraSpeakers => _b.hasSpeakerCount;

  @override
  Future<void> setArrayMode(int mode) async {
    try {
      final code = _b.setArray(mode);
      if (code == -1) return;
      if (code != 0) _check(code);
    } catch (_) {
      // Older DLL without yinwei_set_array.
    }
  }

  @override
  Future<void> setSpeaker({
    required int index,
    required double azimuthDeg,
    required double elevationDeg,
    required double distanceM,
    required double gainDb,
    required bool mute,
    required int feed,
  }) async {
    try {
      final code = _b.setSpeaker(
        index: index,
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        distanceM: distanceM,
        gainDb: gainDb,
        mute: mute,
        feed: feed,
      );
      if (code == -1) return;
      if (code != 0) _check(code);
    } catch (_) {}
  }

  @override
  Future<void> setSpeakerCount(int n) async {
    try {
      final code = _b.setSpeakerCount(n);
      if (code == -1) return;
      if (code != 0) _check(code);
    } catch (_) {}
  }

  void _writeParams(YinweiParamsC ref, SpatialParams p) {
    ref.azimuthDeg = p.azimuthDeg;
    ref.elevationDeg = p.elevationDeg;
    ref.distanceM = p.distanceM;
    ref.motion = p.motion == MotionMode.fixed ? 0 : 1;
    ref.orbitHz = p.orbitHz;
    ref.envelopment = p.envelopment;
    ref.reverbMix = p.reverbMix;
    ref.preset = p.selectedPreset == null ? -1 : _presetIndex(p.selectedPreset!);
  }

  SpatialParams _readParams(YinweiParamsC ref) {
    return SpatialParams(
      azimuthDeg: ref.azimuthDeg,
      elevationDeg: ref.elevationDeg,
      distanceM: ref.distanceM,
      motion: ref.motion == 0 ? MotionMode.fixed : MotionMode.orbit,
      orbitHz: ref.orbitHz,
      envelopment: ref.envelopment,
      reverbMix: ref.reverbMix,
      selectedPreset: _presetFromIndex(ref.preset),
    );
  }

  int _presetIndex(PositionPreset p) => PositionPreset.gridOrder.indexOf(p);

  PositionPreset? _presetFromIndex(int i) {
    if (i < 0 || i >= PositionPreset.gridOrder.length) return null;
    return PositionPreset.gridOrder[i];
  }
}
