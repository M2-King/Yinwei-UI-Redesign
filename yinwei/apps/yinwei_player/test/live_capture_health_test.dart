import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/live_capture_health.dart';

void main() {
  test('silent one-shot frame count is not healthy', () {
    const h = LiveCaptureHealth(
      running: true,
      capturedFrames: 256,
      energyFrames: 0,
      prevCapturedFrames: 0,
      prevEnergyFrames: 0,
    );
    expect(h.healthy, isFalse);
  });

  test('rising energy frames is healthy', () {
    const h = LiveCaptureHealth(
      running: true,
      capturedFrames: 512,
      energyFrames: 128,
      prevCapturedFrames: 256,
      prevEnergyFrames: 0,
    );
    expect(h.healthy, isTrue);
  });

  test('rising frames plus recent energy is healthy', () {
    const h = LiveCaptureHealth(
      running: true,
      capturedFrames: 900,
      energyFrames: 400,
      prevCapturedFrames: 800,
      prevEnergyFrames: 400,
      lastEnergyAgeMs: 400,
    );
    expect(h.healthy, isTrue);
  });

  test('a few quiet seconds still counts as recent energy', () {
    const h = LiveCaptureHealth(
      running: true,
      capturedFrames: 900,
      energyFrames: 400,
      prevCapturedFrames: 800,
      prevEnergyFrames: 400,
      lastEnergyAgeMs: 2500,
    );
    expect(h.healthy, isTrue);
  });

  test('stalled capture is not healthy', () {
    const h = LiveCaptureHealth(
      running: true,
      capturedFrames: 800,
      energyFrames: 400,
      prevCapturedFrames: 800,
      prevEnergyFrames: 400,
      lastEnergyAgeMs: 8000,
    );
    expect(h.healthy, isFalse);
  });

  test('not running is never healthy', () {
    const h = LiveCaptureHealth(
      running: false,
      capturedFrames: 9999,
      energyFrames: 9999,
      prevCapturedFrames: 0,
      prevEnergyFrames: 0,
    );
    expect(h.healthy, isFalse);
  });
}
