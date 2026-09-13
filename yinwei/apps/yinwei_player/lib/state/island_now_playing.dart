import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';

enum IslandMediaSource { yinwei, system, idle }

/// Merges Yinwei engine session with Windows SMTC for the island strip.
///
/// [liveTransfer] is WASAPI loopback HRTF only (healthy capture).
/// File Spatial uses [yinweiSpatial] — never the HRTF LIVE flag.
class IslandNowPlaying {
  const IslandNowPlaying({
    required this.source,
    required this.title,
    required this.artist,
    required this.album,
    required this.playing,
    required this.playhead,
    required this.duration,
    required this.liveTransfer,
    required this.yinweiSpatial,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.envelopment,
    required this.orbiting,
    required this.subtitle,
  });

  final IslandMediaSource source;
  final String title;
  final String artist;
  final String album;
  final bool playing;
  final double playhead;
  final Duration duration;
  final bool liveTransfer;
  final bool yinweiSpatial;
  final double azimuthDeg;
  final double elevationDeg;
  final double envelopment;
  final bool orbiting;
  final String subtitle;

  bool get usesSystemMedia => source == IslandMediaSource.system;

  TrackMeta get asTrack => TrackMeta(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
      );

  Duration get position {
    final total = duration.inMilliseconds;
    if (total <= 0) return Duration.zero;
    final ms = (playhead * total).round();
    if (ms < 0) return Duration.zero;
    if (ms > total) return duration;
    return Duration(milliseconds: ms);
  }

  factory IslandNowPlaying.resolve({
    required EngineController engine,
    required SystemMediaState system,
    required DateTime now,
    bool liveHrtfRunning = false,
    bool liveHrtfHealthy = false,
    double liveAzimuthDeg = 0,
    double liveElevationDeg = 0,
  }) {
    final systemLive = system.hasTrack && system.playing;

    if (liveHrtfHealthy && system.hasTrack) {
      return IslandNowPlaying(
        source: IslandMediaSource.system,
        title: system.title,
        artist: system.artist.isEmpty ? _shortApp(system.sourceApp) : system.artist,
        album: system.album,
        playing: true,
        playhead: system.durationSec > 0
            ? (system.positionSec / system.durationSec).clamp(0.0, 1.0)
            : 0.0,
        duration: system.durationSec > 0
            ? Duration(milliseconds: (system.durationSec * 1000).round())
            : Duration.zero,
        liveTransfer: true,
        yinweiSpatial: false,
        azimuthDeg: liveAzimuthDeg,
        elevationDeg: liveElevationDeg,
        envelopment: engine.params.envelopment,
        orbiting: engine.params.motion == MotionMode.orbit,
        subtitle:
            'HRTF LIVE · pid ${system.pid} · az ${liveAzimuthDeg.toStringAsFixed(0)}°',
      );
    }

    if (liveHrtfRunning && system.hasTrack) {
      return IslandNowPlaying(
        source: IslandMediaSource.system,
        title: system.title,
        artist: system.artist.isEmpty ? _shortApp(system.sourceApp) : system.artist,
        album: system.album,
        playing: system.playing,
        playhead: system.durationSec > 0
            ? (system.positionSec / system.durationSec).clamp(0.0, 1.0)
            : 0.0,
        duration: system.durationSec > 0
            ? Duration(milliseconds: (system.durationSec * 1000).round())
            : Duration.zero,
        liveTransfer: false,
        yinweiSpatial: false,
        azimuthDeg: liveAzimuthDeg,
        elevationDeg: liveElevationDeg,
        envelopment: engine.params.envelopment,
        orbiting: false,
        subtitle: '环回捕获中 · 听感未验收 · 请在全窗 A/B',
      );
    }

    // Prefer Yinwei when it owns an opened file (playing or paused).
    if (engine.hasOpenedFile && (engine.playing || !systemLive)) {
      final spatial = engine.mode == PlaybackMode.spatial;
      final fileSpatial = spatial && engine.playing;
      return IslandNowPlaying(
        source: IslandMediaSource.yinwei,
        title: engine.track.title,
        artist: engine.track.artist,
        album: engine.track.album,
        playing: engine.playing,
        playhead: engine.playhead,
        duration: engine.track.duration,
        liveTransfer: false,
        yinweiSpatial: fileSpatial,
        azimuthDeg: engine.azimuthDeg,
        elevationDeg: engine.elevationDeg,
        envelopment: engine.params.envelopment,
        orbiting: fileSpatial && engine.params.motion == MotionMode.orbit,
        subtitle: fileSpatial
            ? 'Yinwei Spatial  az ${engine.azimuthDeg.toStringAsFixed(0)}°'
            : (spatial ? 'Yinwei · Spatial ready' : 'Yinwei · Original'),
      );
    }

    if (system.hasTrack) {
      final dur = system.durationSec > 0
          ? Duration(milliseconds: (system.durationSec * 1000).round())
          : Duration.zero;
      final head = system.durationSec > 0
          ? (system.positionSec / system.durationSec).clamp(0.0, 1.0)
          : 0.0;
      final app = _shortApp(system.sourceApp);
      return IslandNowPlaying(
        source: IslandMediaSource.system,
        title: system.title,
        artist: system.artist.isEmpty ? app : system.artist,
        album: system.album,
        playing: system.playing,
        playhead: head,
        duration: dur,
        liveTransfer: false,
        yinweiSpatial: false,
        azimuthDeg: 0,
        elevationDeg: 0,
        envelopment: 0.35,
        orbiting: false,
        subtitle: system.playing
            ? 'SMTC · $app · 全窗 Transfer（预览叠听）'
            : 'SMTC · $app paused',
      );
    }

    return IslandNowPlaying(
      source: IslandMediaSource.idle,
      title: engine.track.title,
      artist: engine.track.artist,
      album: engine.track.album,
      playing: false,
      playhead: engine.playhead,
      duration: engine.track.duration,
      liveTransfer: false,
      yinweiSpatial: false,
      azimuthDeg: engine.azimuthDeg,
      elevationDeg: engine.elevationDeg,
      envelopment: engine.params.envelopment,
      orbiting: false,
      subtitle: '打开文件或播放系统音乐',
    );
  }

  static String _shortApp(String aumid) {
    if (aumid.isEmpty) return 'System';
    final lower = aumid.toLowerCase();
    if (lower.contains('soda') ||
        aumid.contains('汽水') ||
        lower.contains('netease') ||
        lower.contains('cloudmusic')) {
      return '汽水音乐';
    }
    final parts = aumid.split(RegExp(r'[.!\\]'));
    final last = parts.isNotEmpty ? parts.last : aumid;
    return last.length > 18 ? '${last.substring(0, 16)}…' : last;
  }
}
