import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _DelayedEngine extends MockEngine {
  Completer<void>? nextWrite;
  int writes = 0;
  @override
  Future<void> setParams(SpatialParams params) async {
    ++writes;
    await nextWrite?.future;
    await super.setParams(params);
  }
}

void main() {
  late EngineController controller;
  late SpatialRuntimeAdapter spatial;
  late AppSessionCoordinator coordinator;
  late _DelayedEngine engine;
  late DateTime now;
  late bool live;
  setUp(() async {
    now = DateTime(2026, 10, 12);
    live = false;
    engine = _DelayedEngine();
    controller = EngineController(engine: engine);
    spatial = SpatialRuntimeAdapter()..bootstrap(controller.params);
    coordinator = AppSessionCoordinator(
        controller: controller,
        spatial: spatial,
        nativeBackend: true,
        liveRunning: () => live,
        now: () => now);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    await coordinator.close();
    controller.dispose();
  });

  Map<String, dynamic> pointCommand(String device,
      {String id = 'command_001'}) {
    final snapshot = coordinator.snapshot();
    final lease = coordinator.acquireControl(device);
    return {
      'protocolVersion': 1,
      'commandId': id,
      'hostSessionId': snapshot['hostSessionId'],
      'controlLeaseId': lease['controlLeaseId'],
      'expectedStateVersion': snapshot['stateVersion'],
      'expectedSceneRevision': snapshot['sceneRevision'],
      'type': 'point.set',
      'payload': {'azimuthDeg': -90, 'elevationDeg': 30, 'distanceM': 2.5}
    };
  }

  test('Point commands use the existing store and await the native call',
      () async {
    final input = pointCommand('device');
    engine.nextWrite = Completer<void>();
    var completed = false;
    final result = coordinator.command('device', input)
      ..then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(spatial.appliedRevision, 2);
    engine.nextWrite!.complete();
    expect((await result)['status'], 'native_applied');
    expect(controller.params.azimuthDeg, -90);
    expect(controller.params.elevationDeg, closeTo(30, 1e-8));
  });

  test('retries return the same result without a second write', () async {
    final input = pointCommand('device');
    await coordinator.command('device', input);
    final writes = engine.writes;
    await coordinator.command('device', input);
    expect(engine.writes, writes);
    expect(spatial.appliedRevision, 2);
    expect(() => coordinator.command('device', {...input, 'type': 'pause'}),
        throwsA(isA<RemoteFailure>()));
  });

  test('a second device cannot take over an active control lease', () {
    coordinator.acquireControl('first');
    expect(() => coordinator.acquireControl('second'),
        throwsA(isA<RemoteFailure>()));
  });

  test('expired control and stale state never write native params', () async {
    final input = pointCommand('device');
    now = now.add(const Duration(seconds: 31));
    final writes = engine.writes;
    await expectLater(
        coordinator.command('device', input), throwsA(isA<RemoteFailure>()));
    expect(engine.writes, writes);
  });

  test('local control invalidates an already queued remote command', () async {
    final input = pointCommand('device');
    final result = coordinator.command('device', input);
    coordinator.takeLocalControl();
    await expectLater(result, throwsA(isA<RemoteFailure>()));
    expect(spatial.appliedRevision, 1);
  });

  test('native failure is reported as failed, never as applied', () async {
    final input = pointCommand('device');
    engine.nextWrite = Completer<void>();
    final result = coordinator.command('device', input);
    final expectation = expectLater(result, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    engine.nextWrite!.completeError(StateError('native failed'));
    await expectation;
    expect(coordinator.lastCommandStatus, 'failed');
  });

  test('live capture and array prevent unsupported remote Point mutation',
      () async {
    final input = pointCommand('device');
    live = true;
    await expectLater(
        coordinator.command('device', input), throwsA(isA<RemoteFailure>()));
    expect(spatial.appliedRevision, 1);
  });

  test('approved media IDs are returned without private filesystem paths', () {
    coordinator.registerLocalMedia(r'C:\private\song.wav', 'Song');
    final state = coordinator.snapshot();
    expect('${state['media']}', isNot(contains(r'C:\private')));
    expect(coordinator.media.single['title'], 'Song');
  });
}
