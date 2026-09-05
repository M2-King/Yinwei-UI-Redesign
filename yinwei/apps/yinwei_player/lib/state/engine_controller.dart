import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Bumped when UI wiring changes — shown in status bar so Windows hosts
/// can confirm they pulled the latest build.
const String kYinweiUiBuild = 'ui-6';
const String kYinweiBridgeBuild = 'p2.4.1-live';

/// App state for the locked Player UI (IMPLEMENTATION_P2 §5.1).
class EngineController extends ChangeNotifier {
  EngineController({EngineApi? engine, this.backendLabel = 'Mock'})
      : _engine = engine ?? MockEngine() {
    // Keep engine params aligned with UI defaults immediately.
    unawaited(_engine.setParams(params));
  }

  final EngineApi _engine;
  final String backendLabel;

  TrackMeta track = TrackMeta.demo;
  SpatialParams params = SpatialParams();
  PlaybackMode mode = PlaybackMode.spatial;
  bool playing = false;
  Duration position = const Duration(minutes: 1, seconds: 42);
  double azimuthDeg = 90;
  double jobProgress = 0;
  bool busy = false;
  String? lastError;
  bool hasOpenedFile = false;

  Timer? _tick;
  Timer? _liveRebuild;
  int _liveGen = 0;

  double get playhead {
    final total = track.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Future<void> openPath(String path) async {
    _liveRebuild?.cancel();
    await _run(() async {
      track = await _engine.open(path);
      hasOpenedFile = true;
      position = Duration.zero;
      playing = false;
      _tick?.cancel();
      await _engine.setParams(params);
      await _engine.rebuildPreview(onProgress: _onProgress);
      _syncAzimuth();
    });
  }

  Future<void> setParams(SpatialParams next) async {
    params = next.copy();
    _syncAzimuth();
    notifyListeners(); // sync UI first — don't wait on engine
    await _engine.setParams(params);
    _scheduleLiveRebuild();
  }

  Future<void> applyPreset(PositionPreset preset) async {
    final next = params.copy()..applyPreset(preset);
    params = next;
    _syncAzimuth();
    notifyListeners();
    await _engine.setParams(params);
    _scheduleLiveRebuild();
  }

  Future<void> setMode(PlaybackMode next) async {
    mode = next;
    notifyListeners();
    await _engine.setPlaybackMode(next);
    _scheduleLiveRebuild();
  }

  Future<void> togglePlay() async {
    if (playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    lastError = null;
    try {
      final dirty = await _engine.isPreviewDirty();
      if (dirty) {
        busy = true;
        notifyListeners();
        await _engine.rebuildPreview(onProgress: _onProgress);
        busy = false;
      }
      try {
        await _engine.play();
      } catch (e) {
        lastError = e.toString();
      }
      playing = true;
      _startTick();
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pause() async {
    _liveRebuild?.cancel();
    await _engine.pause();
    playing = false;
    _tick?.cancel();
    position = await _engine.position();
    _syncAzimuth();
    notifyListeners();
  }

  Future<void> seek(Duration d) async {
    await _engine.seek(d);
    position = d;
    _syncAzimuth();
    notifyListeners();
  }

  Future<void> exportWav(String outPath) async {
    await _run(() async {
      await _engine.exportWav(outPath, onProgress: _onProgress);
    });
  }

  /// While playing, debounce a preview rebuild so 音位/距离/模式 changes
  /// become audible without pause → play.
  void _scheduleLiveRebuild() {
    _liveRebuild?.cancel();
    if (!playing) return;
    final gen = ++_liveGen;
    _liveRebuild = Timer(const Duration(milliseconds: 220), () async {
      if (gen != _liveGen || !playing) return;
      final dirty = await _engine.isPreviewDirty();
      if (!dirty || !playing) return;
      try {
        busy = true;
        notifyListeners();
        await _engine.rebuildPreview(onProgress: _onProgress);
        if (playing) {
          try {
            await _engine.play();
          } catch (_) {
            // Device errors already surfaced on first play.
          }
        }
        _syncAzimuth();
      } catch (e) {
        lastError = e.toString();
      } finally {
        busy = false;
        jobProgress = 0;
        notifyListeners();
      }
    });
  }

  void _syncAzimuth() {
    azimuthDeg = params.visualAzimuthDeg(position);
  }

  void _onProgress(double p) {
    jobProgress = p;
    notifyListeners();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 33), (_) async {
      if (!playing) return;
      final pos = await _engine.position();
      final still = await _engine.isPlaying();
      position = pos;
      _syncAzimuth();
      playing = still;
      if (!playing) _tick?.cancel();
      notifyListeners();
    });
  }

  Future<void> _run(Future<void> Function() job) async {
    busy = true;
    lastError = null;
    jobProgress = 0;
    notifyListeners();
    try {
      await job();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      busy = false;
      jobProgress = 0;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _liveRebuild?.cancel();
    _tick?.cancel();
    _engine.dispose();
    super.dispose();
  }
}
