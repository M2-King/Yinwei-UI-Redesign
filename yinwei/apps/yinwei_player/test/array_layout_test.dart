import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/bridge/system_media.dart';

void main() {
  test('default array is Point off with stereo 2.0 poses stored', () {
    final a = ArrayLayout();
    expect(a.enabled, isFalse);
    expect(a.mode, ArrayMode.off);
    expect(a.speakers.length, 2);
    expect(a.speakers[0].azimuthDeg, closeTo(-30, 0.01));
    expect(a.speakers[1].azimuthDeg, closeTo(30, 0.01));
    expect(a.speakers[0].distanceM, closeTo(1.8, 0.01));
    expect(a.speakers[0].feed, SpeakerFeed.left);
    expect(a.speakers[1].feed, SpeakerFeed.right);
    expect(a.nativeMode, 0);
  });

  test('applyStereo2Preset enables two speakers at ±30°', () {
    final a = ArrayLayout();
    a.speakers[0].azimuthDeg = -90;
    a.applyStereo2Preset();
    expect(a.enabled, isTrue);
    expect(a.mode, ArrayMode.stereo2);
    expect(a.nativeMode, 1);
    expect(a.shortLabel, '2.0');
    expect(a.speakers.length, 2);
    expect(a.speakers[0].azimuthDeg, closeTo(-30, 0.01));
    expect(a.speakers[1].azimuthDeg, closeTo(30, 0.01));
  });

  test('SpatialParams is unchanged by ArrayLayout', () {
    final p = SpatialParams();
    expect(p.azimuthDeg, 90);
    expect(p.envelopment, 0.6);
  });

  test('island subtitle appends 2.0 when stereo array is on', () {
    final engine = EngineController();
    engine.array.applyStereo2Preset();
    const system = SystemMediaState(
      active: true,
      title: 'Track',
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
    );
    expect(now.subtitle, contains('2.0'));
    expect(now.subtitle, contains('HRTF LIVE'));
    engine.dispose();
  });
}
