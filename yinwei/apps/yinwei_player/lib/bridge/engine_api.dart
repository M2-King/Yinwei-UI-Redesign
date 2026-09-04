/// Stable Engine API per docs/IMPLEMENTATION_P2.md §5.2
library;

import 'package:yinwei_player/models/spatial_params.dart';

abstract class EngineApi {
  Future<TrackMeta> open(String path);

  Future<void> setParams(SpatialParams params);

  Future<SpatialParams> applyPreset(PositionPreset preset);

  Future<void> setPlaybackMode(PlaybackMode mode);

  Future<void> rebuildPreview({void Function(double progress)? onProgress});

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<Duration> position();

  Future<bool> isPlaying();

  Future<double> currentAzimuthDeg();

  Future<void> exportWav(
    String outPath, {
    void Function(double progress)? onProgress,
  });

  Future<void> dispose();

  Future<bool> isPreviewDirty();
}
