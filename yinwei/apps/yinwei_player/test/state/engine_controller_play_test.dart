import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _PendingTickEngine extends MockEngine {
  _PendingTickEngine(this.pendingRead);
  final String pendingRead;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool disposed = false;
  int readsAfterDispose = 0;

  Future<void> _read(String name) async {
    if (disposed) readsAfterDispose++;
    if (name == pendingRead) {
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<Duration> position() async {
    await _read('position');
    return const Duration(seconds: 1);
  }

  @override
  Future<bool> isPlaying() async {
    await _read('playing');
    return true;
  }

  @override
  Future<double> currentAzimuthDeg() async {
    await _read('azimuth');
    return 20;
  }

  @override
  Future<double> currentElevationDeg() async {
    await _read('elevation');
    return 10;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FailingPlayEngine extends MockEngine {
  @override
  Future<void> play() async {
    throw StateError('AudioDevice: no default output device');
  }
}

class _FailingOpenEngine extends MockEngine {
  @override
  Future<TrackMeta> open(String path) async {
    throw StateError('FileNotFound: $path');
  }
}

void main() {
  for (final read in ['position', 'playing', 'azimuth', 'elevation']) {
    test('disposal during pending $read read stops the old playback tick',
        () async {
      final engine = _PendingTickEngine(read);
      final ctrl = EngineController(engine: engine);
      var notifications = 0;
      ctrl.addListener(() => notifications++);
      await ctrl.play();
      await engine.entered.future.timeout(const Duration(seconds: 2));
      final before = notifications;
      ctrl.dispose();
      engine.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(notifications, before);
      expect(engine.readsAfterDispose, 0);
    });
  }

  test('native play failure does not mark the transport as playing', () async {
    final ctrl = EngineController(
      engine: _FailingPlayEngine(),
      backendLabel: 'Native · spatial_core',
    );
    addTearDown(ctrl.dispose);

    await ctrl.play();

    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, contains('AudioDevice'));
  });

  test('successful play still starts the transport', () async {
    final ctrl = EngineController(
      engine: MockEngine(),
      backendLabel: 'Mock',
    );
    addTearDown(ctrl.dispose);

    await ctrl.play();

    expect(ctrl.playing, isTrue);
    expect(ctrl.lastError, isNull);
  });

  test(
      'successful open enables playback and clears a stale NoTrackLoaded error',
      () async {
    final ctrl = EngineController(
      engine: MockEngine(),
      backendLabel: 'Native · spatial_core',
    )..lastError = 'Bad state: NoTrackLoaded: no track loaded';
    addTearDown(ctrl.dispose);

    await ctrl.openPath(r'C:\music\demo.wav');

    expect(ctrl.hasOpenedFile, isTrue);
    expect(ctrl.track.title, 'demo');
    expect(ctrl.track.duration, isNot(Duration.zero));
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, isNull);
  });

  test('native open failure stays visible and does not mark a file opened',
      () async {
    final ctrl = EngineController(
      engine: _FailingOpenEngine(),
      backendLabel: 'Native · spatial_core',
    );
    addTearDown(ctrl.dispose);

    await expectLater(
      ctrl.openPath('missing.wav'),
      throwsA(isA<StateError>()),
    );
    expect(ctrl.hasOpenedFile, isFalse);
    expect(ctrl.playing, isFalse);
    expect(ctrl.lastError, contains('FileNotFound'));
  });
}
