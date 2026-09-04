import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// App state for the locked Player UI (IMPLEMENTATION_P2 §5.1).
class EngineController extends ChangeNotifier {
  EngineController({EngineApi? engine}) : _engine = engine ?? MockEngine();

  final EngineApi _engine;

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

  Future<void> openPath(String path) async {
    await _run(() async {
      track = await _engine.open(path);
      hasOpenedFile = true;
      position = Duration.zero;
      playing = false;
      await _engine.rebuildPreview(onProgress: _onProgress);
      azimuthDeg = await _engine.currentAzimuthDeg();
    });
  }

  Future<void> setParams(SpatialParams next) async {
    params = next.copy();
    notifyListeners();
    await _engine.setParams(params);
  }

  Future<void> applyPreset(PositionPreset preset) async {
    params = await _engine.applyPreset(preset);
    azimuthDeg = params.azimuthDeg;
    notifyListeners();
  }

  Future<void> setMode(PlaybackMode next) async {
    mode = next;
    notifyListeners();
    await _engine.setPlaybackMode(next);
  }

  Future<void> togglePlay() async {
    if (playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    await _run(() async {
      final dirty = await _engine.isPreviewDirty();
      if (dirty) {
        await _engine.rebuildPreview(onProgress: _onProgress);
      }
      try {
        await _engine.play();
      } catch (e) {
        // AudioDevice: still mark playing for mock orbit UI; show message.
        lastError = e.toString();
      }
      playing = true;
      _startTick();
    });
  }

  Future<void> pause() async {
    await _engine.pause();
    playing = false;
    _tick?.cancel();
    position = await _engine.position();
    notifyListeners();
  }

  Future<void> seek(Duration d) async {
    await _engine.seek(d);
    position = d;
    notifyListeners();
  }

  Future<void> exportWav(String outPath) async {
    await _run(() async {
      await _engine.exportWav(outPath, onProgress: _onProgress);
    });
  }

  void _onProgress(double p) {
    jobProgress = p;
    notifyListeners();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!playing) return;
      position = await _engine.position();
      azimuthDeg = await _engine.currentAzimuthDeg();
      playing = await _engine.isPlaying();
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
    _tick?.cancel();
    _engine.dispose();
    super.dispose();
  }
}
