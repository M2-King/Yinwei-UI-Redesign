import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _FailingPlayEngine extends MockEngine {
  @override
  Future<void> play() async {
    throw StateError('AudioDevice: no default output device');
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
}
