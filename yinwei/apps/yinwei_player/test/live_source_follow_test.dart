import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/bridge/live_source_follow.dart';
import 'package:yinwei_player/bridge/system_media.dart';

SystemMediaState _track({
  required int pid,
  required String process,
  required String title,
  bool playing = true,
}) {
  return SystemMediaState(
    active: true,
    title: title,
    playing: playing,
    pid: pid,
    processName: process,
  );
}

void main() {
  const soda = 111;
  const spotify = 222;

  test('source pid change retargets capture and speaker route', () {
    final next = _track(
      pid: spotify,
      process: 'Spotify',
      title: 'New App',
    );
    expect(
      LiveSourceFollow.shouldRetargetCapture(
        transferOn: true,
        capturePid: soda,
        smtc: next,
        captureHealthy: true,
      ),
      isTrue,
    );
    expect(
      LiveSourceFollow.shouldRetargetRoute(
        transferOn: true,
        splitActive: true,
        routedPid: soda,
        smtc: next,
        captureHealthy: true,
      ),
      isTrue,
    );
    expect(
      AppAudioRouter.shouldSkipPin(
        rootPid: spotify,
        routedRootPid: soda,
        isRouted: true,
      ),
      isFalse,
    );
  });

  test('same pid title change does not re-route or recapture', () {
    final next = _track(
      pid: soda,
      process: 'SodaMusic',
      title: 'Next Track',
    );
    expect(
      LiveSourceFollow.shouldRetargetCapture(
        transferOn: true,
        capturePid: soda,
        smtc: next,
        captureHealthy: true,
      ),
      isFalse,
    );
    expect(
      LiveSourceFollow.shouldRetargetRoute(
        transferOn: true,
        splitActive: true,
        routedPid: soda,
        smtc: next,
        captureHealthy: true,
      ),
      isFalse,
    );
    expect(
      AppAudioRouter.shouldSkipPin(
        rootPid: soda,
        routedRootPid: soda,
        isRouted: true,
      ),
      isTrue,
    );
  });

  test('hold wet until pinned only when split exists', () {
    expect(LiveSourceFollow.holdWetUntilPinned(splitDetected: true), isTrue);
    expect(LiveSourceFollow.holdWetUntilPinned(splitDetected: false), isFalse);
  });

  test('yinwei pid is refused', () {
    final self = _track(
      pid: 9,
      process: 'yinwei_player',
      title: 'Feedback',
    );
    expect(
      LiveSourceFollow.shouldRetargetCapture(
        transferOn: true,
        capturePid: soda,
        smtc: self,
        captureHealthy: false,
      ),
      isFalse,
    );
    expect(
      LiveSourceFollow.shouldRetargetRoute(
        transferOn: true,
        splitActive: true,
        routedPid: soda,
        smtc: self,
        captureHealthy: false,
      ),
      isFalse,
    );
  });

  test('paused SMTC refuses live start', () {
    final paused = _track(
      pid: soda,
      process: 'SodaMusic',
      title: 'Borsia',
      playing: false,
    );
    expect(LiveSourceFollow.refuseStartReason(paused), '请先播放 Borsia，再开 HRTF LIVE');
    expect(
      LiveSourceFollow.refuseStartReason(
        _track(pid: soda, process: 'SodaMusic', title: 'Borsia'),
      ),
      isNull,
    );
  });

  test('paused other app does not steal a healthy 汽水 pin', () {
    final paused = _track(
      pid: spotify,
      process: 'Spotify',
      title: 'Other',
      playing: false,
    );
    expect(
      LiveSourceFollow.shouldRetargetRoute(
        transferOn: true,
        splitActive: true,
        routedPid: soda,
        smtc: paused,
        captureHealthy: true,
      ),
      isFalse,
    );
  });
}
