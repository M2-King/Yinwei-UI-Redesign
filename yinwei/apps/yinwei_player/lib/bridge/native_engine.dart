import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Calls into `spatial_core` via flutter_rust_bridge (filled after codegen on Windows).
///
/// Until FRB generate runs, methods throw [UnsupportedError] so UI stays on [MockEngine].
class NativeEngine implements EngineApi {
  @override
  Future<TrackMeta> open(String path) async {
    throw UnsupportedError('NativeEngine: run flutter_rust_bridge_codegen generate');
  }

  @override
  Future<void> setParams(SpatialParams params) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<SpatialParams> applyPreset(PositionPreset preset) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> setPlaybackMode(PlaybackMode mode) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> rebuildPreview({void Function(double progress)? onProgress}) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> play() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> pause() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> seek(Duration position) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<Duration> position() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<bool> isPlaying() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<double> currentAzimuthDeg() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> exportWav(
    String outPath, {
    void Function(double progress)? onProgress,
  }) async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<void> dispose() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }

  @override
  Future<bool> isPreviewDirty() async {
    throw UnsupportedError('NativeEngine: FRB not generated');
  }
}
