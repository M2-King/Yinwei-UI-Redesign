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

  test('switching Point|2.0 keeps extra speakers', () {
    final a = ArrayLayout.stereo2();
    a.addSpeaker(azimuthDeg: -110);
    expect(a.speakers.length, 3);
    a.mode = ArrayMode.off;
    expect(a.speakers.length, 3);
    expect(a.speakers[2].azimuthDeg, closeTo(-110, 0.01));
    a.mode = ArrayMode.stereo2;
    expect(a.speakers.length, 3);
    expect(a.canRemoveSelected, isTrue);
  });

  test('addSpeaker appends Mid point up to 8; L/R cannot be removed', () {
    final a = ArrayLayout.stereo2();
    expect(a.canAddSpeaker, isTrue);
    expect(a.canRemoveSelected, isFalse);
    a.addSpeaker(azimuthDeg: -110);
    expect(a.speakers.length, 3);
    expect(a.speakers[2].feed, SpeakerFeed.mid);
    expect(a.speakers[2].label, '3');
    expect(a.selectedIndex, 2);
    expect(a.canRemoveSelected, isTrue);
    a.selectedIndex = 0;
    expect(a.canRemoveSelected, isFalse);
    a.selectedIndex = 2;
    a.removeSelected();
    expect(a.speakers.length, 2);
    for (var i = 0; i < 6; i++) {
      a.addSpeaker();
    }
    expect(a.speakers.length, 8);
    expect(a.canAddSpeaker, isFalse);
    a.addSpeaker();
    expect(a.speakers.length, 8);
  });

  test('matrix links distance and spread keeps L/R symmetry', () {
    final a = ArrayLayout.stereo2();
    a.speakers[0].distanceM = 1.2;
    a.speakers[1].distanceM = 3.0;
    a.setMatrixLinked(true);
    expect(a.matrixLinked, isTrue);
    expect(a.speakers[0].distanceM, closeTo(a.speakers[1].distanceM, 0.01));
    a.setMatrixSpread(2);
    expect(a.speakers[0].azimuthDeg, closeTo(-60, 0.2));
    expect(a.speakers[1].azimuthDeg, closeTo(60, 0.2));
    a.setMatrixSpread(0.5);
    expect(a.speakers[0].azimuthDeg, closeTo(-15, 0.2));
    expect(a.speakers[1].azimuthDeg, closeTo(15, 0.2));
    a.setAllDistance(4);
    expect(a.speakers[0].distanceM, closeTo(4, 0.01));
    expect(a.speakers[1].distanceM, closeTo(4, 0.01));
    a.moveSelectedInGroup(azimuthDeg: -45);
    expect(a.speakers[0].azimuthDeg, closeTo(-45, 0.2));
    expect(a.speakers[1].azimuthDeg, closeTo(-15, 0.2));
    a.setMatrixLinked(false);
    expect(a.matrixLinked, isFalse);
    expect(a.speakers[0].azimuthDeg, closeTo(-45, 0.2));
  });

  test('SpatialParams is unchanged by ArrayLayout', () {
    final p = SpatialParams();
    expect(p.azimuthDeg, 90);
    expect(p.envelopment, 0.45);
    expect(p.distanceM, 1.8);
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
