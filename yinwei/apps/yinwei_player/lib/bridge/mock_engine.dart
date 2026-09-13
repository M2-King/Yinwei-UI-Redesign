import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// In-Dart stand-in when native `spatial_core` is not linked (CI / UI polish).
class MockEngine implements EngineApi {
  TrackMeta? _track = TrackMeta.demo;
  SpatialParams _params = SpatialParams();
  PlaybackMode _mode = PlaybackMode.spatial;
  bool _playing = false;
  bool _dirty = true;
  Duration _position = const Duration(minutes: 1, seconds: 42);
  DateTime? _playStarted;
  Duration _playAnchor = Duration.zero;

  @override
  Future<TrackMeta> open(String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final name = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
    _track = TrackMeta(
      title: name.isEmpty ? 'Untitled' : name,
      artist: 'Local file',
      album: '',
      duration: const Duration(minutes: 3, seconds: 51),
      path: path,
    );
    _position = Duration.zero;
    _playing = false;
    _dirty = true;
    return _track!;
  }

  @override
  Future<void> setParams(SpatialParams params) async {
    _params = params.copy();
    _dirty = true;
  }

  @override
  Future<SpatialParams> applyPreset(PositionPreset preset) async {
    _params = _params.copy()..applyPreset(preset);
    _dirty = true;
    return _params.copy();
  }

  @override
  Future<void> setPlaybackMode(PlaybackMode mode) async {
    _mode = mode;
    _dirty = true;
  }

  @override
  Future<void> rebuildPreview({void Function(double progress)? onProgress}) async {
    for (var i = 0; i <= 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      onProgress?.call(i / 10);
    }
    _dirty = false;
  }

  @override
  Future<void> play() async {
    if (_track == null) {
      throw StateError('NoTrackLoaded');
    }
    if (_dirty) {
      await rebuildPreview();
    }
    _playAnchor = _position;
    _playStarted = DateTime.now();
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _position = await position();
    _playing = false;
    _playStarted = null;
  }

  @override
  Future<void> seek(Duration position) async {
    final max = _track?.duration ?? Duration.zero;
    _position = position > max ? max : (position.isNegative ? Duration.zero : position);
    if (_playing) {
      _playAnchor = _position;
      _playStarted = DateTime.now();
    }
  }

  @override
  Future<Duration> position() async {
    if (_playing && _playStarted != null) {
      final elapsed = DateTime.now().difference(_playStarted!);
      var p = _playAnchor + elapsed;
      final max = _track?.duration ?? Duration.zero;
      if (p >= max) {
        _playing = false;
        _playStarted = null;
        p = max;
      }
      _position = p;
    }
    return _position;
  }

  @override
  Future<bool> isPlaying() async => _playing;

  @override
  Future<double> currentAzimuthDeg() async {
    // Drive orbit from playhead so seek + play both move the left sphere.
    final pos = await position();
    return _params.visualAzimuthDeg(pos);
  }

  @override
  Future<double> currentElevationDeg() async => _params.elevationDeg;

  @override
  Future<void> exportWav(
    String outPath, {
    void Function(double progress)? onProgress,
  }) async {
    if (_track == null) throw StateError('NoTrackLoaded');
    for (var i = 0; i <= 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      onProgress?.call(i / 10);
    }
  }

  @override
  Future<void> dispose() async {
    _playing = false;
    _track = null;
    _dirty = true;
  }

  @override
  Future<bool> isPreviewDirty() async => _dirty;

  PlaybackMode get mode => _mode;
  SpatialParams get params => _params.copy();
  TrackMeta? get track => _track;
}
