import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';

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

  test('successful open enables playback and clears a stale NoTrackLoaded error',
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
