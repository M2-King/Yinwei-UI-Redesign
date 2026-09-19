import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/yinwei_activity_presentation.dart';

void main() {
  test('compact trailing shows live orbit heading while playing', () {
    const state = YinweiActivityViewState(
      mode: 'spatial',
      playing: true,
      orbiting: true,
      azimuthDeg: 42.4,
      elevationDeg: -10,
      sourceLabel: 'Point',
      title: 'Preview',
    );
    expect(YinweiActivityPresentation.compactTrailing(state), '42°');
    expect(YinweiActivityPresentation.statusLine(state), 'Orbit');
  });

  test('paused orbit keeps the last heading instead of inventing motion', () {
    const playing = YinweiActivityViewState(
      mode: 'spatial',
      playing: true,
      orbiting: true,
      azimuthDeg: 90,
      elevationDeg: 0,
      sourceLabel: 'Point',
      title: 'Preview',
    );
    const paused = YinweiActivityViewState(
      mode: 'spatial',
      playing: false,
      orbiting: false,
      azimuthDeg: 90,
      elevationDeg: 0,
      sourceLabel: 'Point',
      title: 'Preview',
    );
    expect(YinweiActivityPresentation.compactTrailing(playing), '90°');
    expect(YinweiActivityPresentation.compactTrailing(paused), '90°');
    expect(YinweiActivityPresentation.statusLine(paused), 'Paused');
    expect(YinweiActivityPresentation.orbitLabel(paused), 'Frozen');
  });

  test('expanded readout stays low density', () {
    const state = YinweiActivityViewState(
      mode: 'spatial',
      playing: true,
      orbiting: false,
      azimuthDeg: -45.2,
      elevationDeg: 12.6,
      sourceLabel: 'Point',
      title: 'Local file',
    );
    expect(YinweiActivityPresentation.expandedBottom(state), 'Az -45°  El 13°');
    expect(YinweiActivityPresentation.expandedTrailing(state), '-45°');
  });
}
