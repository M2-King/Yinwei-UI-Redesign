import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:yinwei_player/bridge/native_library_locator.dart';

/// Low-level bindings to `spatial_core` C ABI (P2.4).
///
/// [resolvedLibraryPath] is the absolute path of the DLL that was loaded.
/// Background isolates **must** call [loadFromPath] with that same path so
/// Windows does not map a second (often stale) copy of the library — that
/// creates a second GLOBAL session and live setParams/setMode never reach
/// the playing audio thread.
class YinweiBindings {
  YinweiBindings._(this._lib)
      : yinweiLastError =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_last_error'),
        yinweiOpen = _lib.lookupFunction<_OpenNative, _OpenDart>('yinwei_open'),
        yinweiTrackTitle =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_title'),
        yinweiTrackArtist =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_artist'),
        yinweiTrackAlbum =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_album'),
        yinweiTrackPath =
            _lib.lookupFunction<_ErrNative, _ErrDart>('yinwei_track_path'),
        yinweiTrackDurationMs =
            _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_track_duration_ms'),
        yinweiTrackSampleRate =
            _lib.lookupFunction<_U32Native, _U32Dart>('yinwei_track_sample_rate'),
        yinweiSetParams = _lib
            .lookupFunction<_SetParamsNative, _SetParamsDart>('yinwei_set_params'),
        yinweiGetParams = _lib
            .lookupFunction<_GetParamsNative, _GetParamsDart>('yinwei_get_params'),
        yinweiApplyPreset = _lib.lookupFunction<_ApplyPresetNative, _ApplyPresetDart>(
            'yinwei_apply_preset'),
        yinweiSetMode =
            _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_mode'),
        yinweiRebuildPreview =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_rebuild_preview'),
        yinweiPlay = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_play'),
        yinweiPause = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_pause'),
        yinweiSeekMs =
            _lib.lookupFunction<_SeekNative, _SeekDart>('yinwei_seek_ms'),
        yinweiPositionMs =
            _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_position_ms'),
        yinweiIsPlaying =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_is_playing'),
        yinweiCurrentAzimuthDeg = _lib
            .lookupFunction<_F32Native, _F32Dart>('yinwei_current_azimuth_deg'),
        yinweiCurrentElevationDeg = _lib
            .lookupFunction<_F32Native, _F32Dart>('yinwei_current_elevation_deg'),
        yinweiExportWav =
            _lib.lookupFunction<_OpenNative, _OpenDart>('yinwei_export_wav'),
        yinweiDispose =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_dispose'),
        yinweiIsPreviewDirty =
            _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_is_preview_dirty');

  // Kept so the DynamicLibrary mapping stays alive for the process lifetime.
  // ignore: unused_field
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
  final _F32Dart yinweiCurrentElevationDeg;
  final _OpenDart yinweiExportWav;
  final _VoidDart yinweiDispose;
  final _VoidDart yinweiIsPreviewDirty;

  static YinweiBindings? _instance;
  static String? loadError;

  /// Absolute path of the loaded native library (pass into isolates).
  static String? resolvedLibraryPath;

  /// Try load `spatial_core`. Returns null if unavailable.
  static YinweiBindings? tryLoad() {
    if (_instance != null) return _instance;
    try {
      final opened = _openLib();
      resolvedLibraryPath = opened.path;
      _instance = YinweiBindings._(opened.lib);
      loadError = null;
      return _instance;
    } catch (e) {
      loadError = e.toString();
      if (Platform.isIOS) {
        print('[YINWEI_IOS] FFI_LOAD FAIL $e');
      }
      return null;
    }
  }

  /// Load a specific absolute library path (for background isolates).
  ///
  /// iOS statically links `spatial_core`; [NativeLibraryLocator.processToken]
  /// must reopen [DynamicLibrary.process] instead of a DLL path.
  static YinweiBindings loadFromPath(String absolutePath) {
    final lib = absolutePath == NativeLibraryLocator.processToken
        ? DynamicLibrary.process()
        : DynamicLibrary.open(absolutePath);
    resolvedLibraryPath = absolutePath;
    final b = YinweiBindings._(lib);
    _instance = b;
    loadError = null;
    return b;
  }

  static ({DynamicLibrary lib, String path}) _openLib() {
    final mode = NativeLibraryLocator.modeFor(
      isWindows: Platform.isWindows,
      isLinux: Platform.isLinux,
      isMacOS: Platform.isMacOS,
      isIOS: Platform.isIOS,
    );
    if (mode == NativeLibraryLoadMode.iosProcess) {
      if (Platform.isIOS) {
        print('[YINWEI_IOS] FFI_LOAD process');
      }
      return (
        lib: DynamicLibrary.process(),
        path: NativeLibraryLocator.processToken,
      );
    }
    final errors = <String>[];
    if (mode == NativeLibraryLoadMode.windowsDll) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final cwd = Directory.current.path;
      // Prefer the DLL next to the running exe (fresh build) BEFORE bare /
      // cwd names — those often resolve to a stale copy.
      // Prefer the newest existing file. A locked stale spatial_core.dll next
      // to the exe must not beat a freshly copied sibling (e.g. .next.dll).
      final candidates = <String>[
        '$exeDir\\spatial_core.next.dll',
        '$exeDir\\spatial_core.dll',
        '$exeDir\\libspatial_core.dll',
        '$cwd\\build\\windows\\x64\\runner\\Debug\\spatial_core.next.dll',
        '$cwd\\build\\windows\\x64\\runner\\Debug\\spatial_core.dll',
        '$cwd\\build\\windows\\x64\\runner\\Release\\spatial_core.dll',
        '$cwd\\windows\\runner\\spatial_core.dll',
        '$cwd\\spatial_core.dll',
        'spatial_core.dll',
        'libspatial_core.dll',
      ];
      final existing = <File>[];
      for (final name in candidates) {
        final f = File(name);
        if (f.existsSync()) existing.add(f);
      }
      existing.sort((a, b) =>
          b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final f in existing) {
        try {
          final abs = f.absolute.path;
          final lib = DynamicLibrary.open(abs);
          return (lib: lib, path: abs);
        } catch (e) {
          errors.add('${f.path} → $e');
        }
      }
      throw StateError('spatial_core.dll load failed:\n${errors.join('\n')}');
    }
    if (mode == NativeLibraryLoadMode.linuxSo) {
      const name = 'libspatial_core.so';
      return (lib: DynamicLibrary.open(name), path: name);
    }
    if (mode == NativeLibraryLoadMode.macDylib) {
      const name = 'libspatial_core.dylib';
      return (lib: DynamicLibrary.open(name), path: name);
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

  // --- Live WASAPI → HRTF transfer (optional symbols) ---

  int liveStart(int processId) {
    final fn = _lib.lookupFunction<_U32InNative, _U32InDart>('yinwei_live_start');
    return fn(processId);
  }

  int liveStop() {
    final fn = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_live_stop');
    return fn();
  }

  bool liveIsRunning() {
    try {
      final fn = _lib.lookupFunction<_VoidNative, _VoidDart>('yinwei_live_is_running');
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  int liveSetMode(int mode) {
    final fn = _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_live_set_mode');
    return fn(mode);
  }

  double liveAzimuthDeg() {
    final fn = _lib.lookupFunction<_F32Native, _F32Dart>('yinwei_live_azimuth_deg');
    return fn();
  }

  double liveElevationDeg() {
    final fn = _lib.lookupFunction<_F32Native, _F32Dart>('yinwei_live_elevation_deg');
    return fn();
  }

  int liveCapturedFrames() {
    final fn = _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_live_captured_frames');
    return fn();
  }

  int liveSetParams({
    required double azimuthDeg,
    required double elevationDeg,
    required double distanceM,
    required int motion,
    required double orbitHz,
    required double envelopment,
    required double reverbMix,
    required int preset,
  }) {
    final fn = _lib.lookupFunction<_LiveParamsNative, _LiveParamsDart>(
        'yinwei_live_set_params');
    return fn(
      azimuthDeg,
      elevationDeg,
      distanceM,
      motion,
      orbitHz,
      envelopment,
      reverbMix,
      preset,
    );
  }

  int liveEnergyFrames() {
    final fn =
        _lib.lookupFunction<_U64Native, _U64Dart>('yinwei_live_energy_frames');
    return fn();
  }

  int liveLastEnergyMs() {
    final fn = _lib
        .lookupFunction<_U64Native, _U64Dart>('yinwei_live_last_energy_ms');
    return fn();
  }

  List<String> liveListOutputDevices() {
    final fn = _lib.lookupFunction<_ErrNative, _ErrDart>(
        'yinwei_live_list_output_devices');
    const cap = 8192;
    final buf = calloc<Uint8>(cap);
    try {
      final code = fn(buf.cast<Char>(), cap);
      if (code != 0) return const [];
      final raw = buf.cast<Utf8>().toDartString();
      if (raw.isEmpty) return const [];
      return raw
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } finally {
      calloc.free(buf);
    }
  }

  int liveSetOutputDevice(String name) {
    final fn =
        _lib.lookupFunction<_OpenNative, _OpenDart>('yinwei_live_set_output_device');
    final ptr = name.toNativeUtf8();
    try {
      return fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Silence wet output until Dart finishes pinning the source to muted speakers.
  int liveSetOutputHold(bool hold) {
    try {
      final fn = _lib
          .lookupFunction<_I32InNative, _I32InDart>('yinwei_live_set_output_hold');
      return fn(hold ? 1 : 0);
    } catch (_) {
      return -1;
    }
  }

  int setEq(List<double> db) {
    final g = _six(db);
    final fn = _lib.lookupFunction<_EqNative, _EqDart>('yinwei_set_eq');
    return fn(g[0], g[1], g[2], g[3], g[4], g[5]);
  }

  int liveSetEq(List<double> db) {
    final g = _six(db);
    final fn = _lib.lookupFunction<_EqNative, _EqDart>('yinwei_live_set_eq');
    return fn(g[0], g[1], g[2], g[3], g[4], g[5]);
  }

  bool get hasArray {
    try {
      _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_array');
      return true;
    } catch (_) {
      return false;
    }
  }

  int setArray(int mode) {
    try {
      final fn =
          _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_array');
      return fn(mode);
    } catch (_) {
      return -1;
    }
  }

  int liveSetArray(int mode) {
    try {
      final fn = _lib
          .lookupFunction<_I32InNative, _I32InDart>('yinwei_live_set_array');
      return fn(mode);
    } catch (_) {
      return -1;
    }
  }

  int setSpeaker({
    required int index,
    required double azimuthDeg,
    required double elevationDeg,
    required double distanceM,
    required double gainDb,
    required bool mute,
    required int feed,
  }) {
    try {
      final fn =
          _lib.lookupFunction<_SpeakerNative, _SpeakerDart>('yinwei_set_speaker');
      return fn(index, azimuthDeg, elevationDeg, distanceM, gainDb, mute ? 1 : 0,
          feed);
    } catch (_) {
      return -1;
    }
  }

  int liveSetSpeaker({
    required int index,
    required double azimuthDeg,
    required double elevationDeg,
    required double distanceM,
    required double gainDb,
    required bool mute,
    required int feed,
  }) {
    try {
      final fn = _lib.lookupFunction<_SpeakerNative, _SpeakerDart>(
          'yinwei_live_set_speaker');
      return fn(index, azimuthDeg, elevationDeg, distanceM, gainDb, mute ? 1 : 0,
          feed);
    } catch (_) {
      return -1;
    }
  }

  bool get hasSpeakerCount {
    try {
      _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_speaker_count');
      return true;
    } catch (_) {
      return false;
    }
  }

  int setSpeakerCount(int n) {
    try {
      final fn =
          _lib.lookupFunction<_I32InNative, _I32InDart>('yinwei_set_speaker_count');
      return fn(n);
    } catch (_) {
      return -1;
    }
  }

  int liveSetSpeakerCount(int n) {
    try {
      final fn = _lib.lookupFunction<_I32InNative, _I32InDart>(
          'yinwei_live_set_speaker_count');
      return fn(n);
    } catch (_) {
      return -1;
    }
  }

  static List<double> _six(List<double> db) {
    return [
      db.isNotEmpty ? db[0] : 0,
      db.length > 1 ? db[1] : 0,
      db.length > 2 ? db[2] : 0,
      db.length > 3 ? db[3] : 0,
      db.length > 4 ? db[4] : 0,
      db.length > 5 ? db[5] : 0,
    ];
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
typedef _U32InNative = Int32 Function(Uint32);
typedef _U32InDart = int Function(int);
typedef _LiveParamsNative = Int32 Function(
    Float, Float, Float, Int32, Float, Float, Float, Int32);
typedef _LiveParamsDart = int Function(
    double, double, double, int, double, double, double, int);
typedef _EqNative = Int32 Function(Float, Float, Float, Float, Float, Float);
typedef _EqDart = int Function(double, double, double, double, double, double);
typedef _SpeakerNative = Int32 Function(
    Int32, Float, Float, Float, Float, Int32, Int32);
typedef _SpeakerDart = int Function(
    int, double, double, double, double, int, int);
