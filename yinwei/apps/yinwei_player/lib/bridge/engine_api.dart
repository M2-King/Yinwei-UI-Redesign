/// Bridge stubs for `flutter_rust_bridge` → `spatial_core`.
///
/// Replace method bodies with generated FRB bindings once the Rust DSP
/// crate is linked. Keep signatures stable so UI does not churn.
library;

import 'package:yinwei_player/models/spatial_params.dart';

abstract final class EngineApi {
  static Future<TrackMeta> open(String path) async {
    throw UnimplementedError('FRB: Engine::open');
  }

  static Future<void> setParams(SpatialParams params) async {
    throw UnimplementedError('FRB: Engine::set_params');
  }

  static Future<void> setPlaybackMode(PlaybackMode mode) async {
    throw UnimplementedError('FRB: Engine::set_playback_mode');
  }

  static Future<void> play() async {
    throw UnimplementedError('FRB: Engine::play');
  }

  static Future<void> pause() async {
    throw UnimplementedError('FRB: Engine::pause');
  }

  static Future<void> seek(Duration position) async {
    throw UnimplementedError('FRB: Engine::seek');
  }

  static Future<void> exportWav(String outPath) async {
    throw UnimplementedError('FRB: Engine::export_wav');
  }

  static Future<double> currentAzimuthDeg() async {
    throw UnimplementedError('FRB: Engine::current_azimuth_deg');
  }
}
