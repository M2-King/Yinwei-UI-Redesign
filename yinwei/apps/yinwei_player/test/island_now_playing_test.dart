import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';

void main() {
  test('prefers SMTC when Yinwei has no opened file', () {
    final engine = EngineController();
    const system = SystemMediaState(
      active: true,
      title: '勇往直前',
      artist: 'Artist',
      playing: true,
      positionSec: 19,
      durationSec: 247,
      sourceApp: 'SodaMusic.exe',
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(now.source, IslandMediaSource.system);
    expect(now.title, '勇往直前');
    expect(now.liveTransfer, isFalse);
    expect(now.yinweiSpatial, isFalse);
    expect(now.subtitle, isNot(contains('HRTF LIVE')));
    expect(now.subtitle, isNot(contains('Yinwei LIVE')));
    expect(now.subtitle, contains('全窗 Transfer'));
    engine.dispose();
  });

  test('file Spatial is Yinwei Spatial, not loopback liveTransfer', () {
    final engine = EngineController();
    engine.hasOpenedFile = true;
    engine.playing = true;
    engine.mode = PlaybackMode.spatial;
    const system = SystemMediaState(
      active: true,
      title: '汽水曲',
      artist: 'Other',
      playing: true,
      sourceApp: 'SodaMusic.exe',
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
    );
    expect(now.source, IslandMediaSource.yinwei);
    expect(now.liveTransfer, isFalse);
    expect(now.yinweiSpatial, isTrue);
    expect(now.subtitle, contains('Yinwei Spatial'));
    expect(now.subtitle, isNot(contains('HRTF LIVE')));
    expect(now.subtitle, isNot(contains('Yinwei LIVE')));
    engine.dispose();
  });

  test('healthy loopback sets liveTransfer HRTF LIVE', () {
    final engine = EngineController();
    const system = SystemMediaState(
      active: true,
      title: '勇往直前',
      artist: 'Artist',
      playing: true,
      sourceApp: 'SodaMusic.exe',
      pid: 4242,
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
      liveHrtfRunning: true,
      liveHrtfHealthy: true,
      liveAzimuthDeg: 90,
    );
    expect(now.liveTransfer, isTrue);
    expect(now.yinweiSpatial, isFalse);
    expect(now.subtitle, contains('HRTF LIVE'));
    expect(now.subtitle, contains('4242'));
    engine.dispose();
  });

  test('running but unhealthy loopback does not fake HRTF LIVE', () {
    final engine = EngineController();
    const system = SystemMediaState(
      active: true,
      title: '勇往直前',
      artist: 'Artist',
      playing: true,
      sourceApp: 'SodaMusic.exe',
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
      liveHrtfRunning: true,
      liveHrtfHealthy: false,
    );
    expect(now.liveTransfer, isFalse);
    expect(now.subtitle, isNot(contains('HRTF LIVE')));
    expect(now.subtitle, contains('捕获中'));
    engine.dispose();
  });

  test('live HRTF uses SMTC title and timeline, not idle demo file', () {
    final engine = EngineController();
    expect(engine.track.title, 'Across the Room');
    expect(engine.hasOpenedFile, isFalse);
    const system = SystemMediaState(
      active: true,
      title: "The World's Biggest Airport is About to Land",
      artist: 'YouTube',
      album: 'Chrome',
      playing: true,
      positionSec: 12,
      durationSec: 600,
      sourceApp: 'chrome',
      pid: 13580,
      processName: 'chrome',
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
      liveHrtfRunning: true,
      liveHrtfHealthy: true,
    );
    expect(now.source, IslandMediaSource.system);
    expect(now.usesSystemMedia, isTrue);
    expect(now.title, "The World's Biggest Airport is About to Land");
    expect(now.album, 'Chrome');
    expect(now.asTrack.title, isNot('Across the Room'));
    expect(now.playhead, closeTo(12 / 600, 0.0001));
    expect(now.position, const Duration(seconds: 12));
    expect(now.duration, const Duration(seconds: 600));
    engine.dispose();
  });

  test('no file + SMTC track uses system timeline when Transfer is off', () {
    final engine = EngineController();
    const system = SystemMediaState(
      active: true,
      title: '汽水曲',
      artist: 'Artist',
      playing: true,
      positionSec: 30,
      durationSec: 120,
      sourceApp: 'SodaMusic.exe',
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
    );
    expect(now.source, IslandMediaSource.system);
    expect(now.title, '汽水曲');
    expect(now.playhead, closeTo(0.25, 0.0001));
    engine.dispose();
  });

  test('opened playing file with Transfer off keeps file session', () {
    final engine = EngineController();
    engine.hasOpenedFile = true;
    engine.playing = true;
    engine.track = const TrackMeta(
      title: 'Local Wav',
      artist: 'Me',
      album: 'Demo',
      duration: Duration(minutes: 3),
    );
    engine.position = const Duration(seconds: 40);
    const system = SystemMediaState(
      active: true,
      title: 'Chrome video',
      artist: 'YouTube',
      playing: true,
      sourceApp: 'chrome',
      pid: 9,
    );
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: system,
      now: DateTime.now(),
    );
    expect(now.source, IslandMediaSource.yinwei);
    expect(now.usesSystemMedia, isFalse);
    expect(now.title, 'Local Wav');
    engine.dispose();
  });

  test('idle falls back to demo prompt when nothing plays', () {
    final engine = EngineController();
    final now = IslandNowPlaying.resolve(
      engine: engine,
      system: SystemMediaState.empty,
      now: DateTime.now(),
    );
    expect(now.source, IslandMediaSource.idle);
    expect(now.liveTransfer, isFalse);
    expect(now.subtitle, contains('打开文件'));
    engine.dispose();
  });
}
