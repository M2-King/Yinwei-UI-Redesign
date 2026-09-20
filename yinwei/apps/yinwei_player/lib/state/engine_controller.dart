import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Bumped when UI wiring changes — shown in status bar so Windows hosts
/// can confirm they pulled the latest build.
const String kYinweiUiBuild = 'ui-53-workspace';
const String kYinweiBridgeBuild = 'p2.4.32-matrix';

/// App state for the locked Player UI (IMPLEMENTATION_P2 §5.1).
class EngineController extends ChangeNotifier {
  EngineController({EngineApi? engine, this.backendLabel = 'Mock'})
      : _engine = engine ?? MockEngine() {
    // Keep engine params aligned with UI defaults immediately.
    unawaited(_pushNativeParams(params));
  }

  final EngineApi _engine;
  final String backendLabel;

  TrackMeta track = TrackMeta.demo;
  SpatialParams params = SpatialParams();
  ArrayLayout array = ArrayLayout();
  PlaybackMode mode = PlaybackMode.spatial;
  bool playing = false;
  Duration position = const Duration(minutes: 1, seconds: 42);
  double azimuthDeg = 90;
  double elevationDeg = -10;
  double jobProgress = 0;
  bool busy = false;
  String? lastError;
  bool hasOpenedFile = false;

  Timer? _tick;
  Timer? _liveRebuild;
  Timer? _paramsThrottle;
  int _liveGen = 0;
  int _paramsGen = 0;
  SpatialParams? _pendingParams;
  ArrayLayout? _pendingArray;
  Timer? _arrayThrottle;
  int _arrayGen = 0;
  var _tickInFlight = false;
  int spatialSetParamsCalls = 0;
  int nativeSpatialWrites = 0;

  bool get arraySupported => _engine.supportsArray;

  bool get extraSpeakersSupported => _engine.supportsExtraSpeakers;

  double get playhead {
    final total = track.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Future<void> openPath(String path) async {
    _liveRebuild?.cancel();
    await _run(() async {
      track =       await _engine.open(path);
      hasOpenedFile = true;
      position = Duration.zero;
      playing = false;
      _tick?.cancel();
      await _pushNativeParams(params);
      // No full-song rebuild — native open() loads dry PCM for streaming DSP.
      _syncAzimuth();
    });
  }

  Future<void> setParams(SpatialParams next) async {
    spatialSetParamsCalls++;
    params = next.copy();
    _syncAzimuth();
    notifyListeners(); // UI follows every frame
    // Throttle native writes during drag/slider floods so FFI + DSP mutex
    // contention doesn't hitch the audio callback.
    _pendingParams = params.copy();
    _paramsThrottle ??= Timer(const Duration(milliseconds: 32), () {
      _paramsThrottle = null;
      final pending = _pendingParams;
      if (pending == null) return;
      _pendingParams = null;
      final gen = ++_paramsGen;
      unawaited(() async {
        await _pushNativeParams(pending);
        if (gen != _paramsGen) return;
      }());
    });
  }

  Future<void> setArray(ArrayLayout next) async {
    array = next.copy();
    notifyListeners();
    _pendingArray = array.copy();
    _arrayThrottle ??= Timer(const Duration(milliseconds: 32), () {
      _arrayThrottle = null;
      final pending = _pendingArray;
      if (pending == null) return;
      _pendingArray = null;
      final gen = ++_arrayGen;
      unawaited(() async {
        await _pushArray(pending);
        if (gen != _arrayGen) return;
      }());
    });
  }

  Future<void> applyArrayMode(ArrayMode mode) async {
    final next = array.copy();
    if (mode == ArrayMode.stereo2) {
      if (next.speakers.length < 2) {
        next.applyStereo2Preset();
      } else {
        next.mode = ArrayMode.stereo2;
      }
    } else {
      next.mode = ArrayMode.off;
    }
    array = next;
    notifyListeners();
    _arrayThrottle?.cancel();
    _arrayThrottle = null;
    _pendingArray = null;
    final gen = ++_arrayGen;
    await _pushArray(array);
    if (gen != _arrayGen) return;
  }

  Future<void> selectArraySpeaker(int index) async {
    if (index < 0 || index >= array.speakers.length) return;
    final next = array.copy()..selectedIndex = index;
    array = next;
    notifyListeners();
  }

  Future<void> _pushArray(ArrayLayout layout) async {
    await _engine.setArrayMode(layout.nativeMode);
    if (!layout.enabled) return;
    await _engine.setSpeakerCount(layout.speakers.length);
    for (var i = 0; i < layout.speakers.length; i++) {
      final s = layout.speakers[i];
      await _engine.setSpeaker(
        index: i,
        azimuthDeg: s.azimuthDeg,
        elevationDeg: s.elevationDeg,
        distanceM: s.distanceM,
        gainDb: s.gainDb,
        mute: s.mute,
        feed: s.nativeFeed,
      );
    }
  }

  Future<void> applyPreset(PositionPreset preset) async {
    final next = params.copy()..applyPreset(preset);
    params = next;
    // Keep target in params; live az/el follow DSP slew while playing Spatial.
    if (!playing || mode != PlaybackMode.spatial) {
      _syncAzimuth();
    }
    notifyListeners();
    // Presets apply immediately (no throttle); native slews HRTF pose without
    // flushing the ring, so this should not stall playback.
    _paramsThrottle?.cancel();
    _paramsThrottle = null;
    _pendingParams = null;
    final gen = ++_paramsGen;
    await _pushNativeParams(params);
    if (gen != _paramsGen) return;
  }

  Future<void> applyEq(EqSequence seq) async {
    final next = params.copy()..applyEq(seq);
    params = next;
    if (!playing || mode != PlaybackMode.spatial) {
      _syncAzimuth();
    }
    notifyListeners();
    _paramsThrottle?.cancel();
    _paramsThrottle = null;
    _pendingParams = null;
    final gen = ++_paramsGen;
    await _pushNativeParams(params);
    if (gen != _paramsGen) return;
  }

  Future<void> setMode(PlaybackMode next) async {
    mode = next;
    notifyListeners();
    // Streaming DSP switches Original/Spatial without re-rendering the track.
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
    lastError = null;
    try {
      // Streaming path: open() already loaded dry PCM; play starts the DSP worker.
      // A failed native start must not flip the transport to playing — the 33ms
      // tick would otherwise snap it back with no visible error.
      await _engine.play();
      playing = true;
      _startTick();
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      playing = false;
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

  /// Previously debounced a full-song HRTF rebuild (caused multi-second mutes).
  /// Streaming DSP applies params live — kept as a no-op for call-site safety.
  void _scheduleLiveRebuild() {
    _liveRebuild?.cancel();
  }

  void _syncAzimuth() {
    if (playing &&
        mode == PlaybackMode.spatial &&
        params.motion == MotionMode.orbit) {
      azimuthDeg = params.visualAzimuthDeg(position);
    } else {
      azimuthDeg = params.azimuthDeg;
    }
    elevationDeg = params.elevationDeg;
  }

  Future<void> _syncLivePose() async {
    if (playing && mode == PlaybackMode.spatial) {
      azimuthDeg = await _engine.currentAzimuthDeg();
      elevationDeg = await _engine.currentElevationDeg();
    } else {
      _syncAzimuth();
    }
  }

  void _onProgress(double p) {
    jobProgress = p;
    notifyListeners();
  }

  void _startTick() {
    _tick?.cancel();
    _tickInFlight = false;
    _tick = Timer.periodic(const Duration(milliseconds: 33), (_) async {
      if (!playing || _tickInFlight) return;
      _tickInFlight = true;
      try {
        final pos = await _engine.position();
        if (!playing) return;
        final still = await _engine.isPlaying();
        position = pos;
        await _syncLivePose();
        playing = still;
        if (!playing) _tick?.cancel();
        notifyListeners();
      } finally {
        _tickInFlight = false;
      }
    });
  }

  Future<void> _pushNativeParams(SpatialParams next) async {
    nativeSpatialWrites++;
    await _engine.setParams(next);
  }

  Map<String, Object?> runtimeAudioDiag() {
    return {
      'uiBuild': kYinweiUiBuild,
      'bridgeBuild': kYinweiBridgeBuild,
      'backend': backendLabel,
      'playbackMode': mode.name,
      'arrayEnabled': array.enabled,
      'arrayMode': array.mode.name,
      'matrixLinked': array.matrixLinked,
      'speakers': [
        for (final s in array.speakers)
          {
            'label': s.label,
            'az': s.azimuthDeg,
            'el': s.elevationDeg,
            'dist': s.distanceM,
            'feed': s.feed.name,
          },
      ],
      'pointAz': params.azimuthDeg,
      'pointEl': params.elevationDeg,
      'pointDist': params.distanceM,
      'nativeSpatialWrites': nativeSpatialWrites,
      'spatialSetParamsCalls': spatialSetParamsCalls,
    };
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
    _paramsThrottle?.cancel();
    _liveRebuild?.cancel();
    _arrayThrottle?.cancel();
    _tick?.cancel();
    _engine.dispose();
    super.dispose();
  }
}
