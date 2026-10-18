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

  group('live control hooks', () {
    late AppSessionCoordinator liveCoordinator;
    final liveParams = <SpatialParams>[];
    final liveModes = <PlaybackMode>[];
    final mediaActions = <String>[];
    final liveCalls = <String>[];
    final arrayModes = <ArrayMode>[];
    Object? startFailure;
    var commandSeq = 0;

    setUp(() {
      liveParams.clear();
      liveModes.clear();
      mediaActions.clear();
      liveCalls.clear();
      arrayModes.clear();
      startFailure = null;
      live = true;
      liveCoordinator = AppSessionCoordinator(
          controller: controller,
          spatial: spatial,
          nativeBackend: true,
          liveRunning: () => live,
          applyLiveParams: (params) async {
            liveParams.add(params);
            await controller.setParamsAcknowledged(params);
          },
          applyLiveMode: (mode) async => liveModes.add(mode),
          liveMedia: (action) async => mediaActions.add(action),
          startLive: () async {
            liveCalls.add('start');
            if (startFailure != null) throw startFailure!;
            live = true;
          },
          stopLive: () async {
            liveCalls.add('stop');
            live = false;
          },
          applyArrayMode: (mode) async {
            arrayModes.add(mode);
            await controller.applyArrayMode(mode);
          },
          now: () => now);
    });
    tearDown(() => liveCoordinator.close());

    Map<String, dynamic> command(String type, Map<String, dynamic> payload) {
      final snapshot = liveCoordinator.snapshot();
      final lease = liveCoordinator.acquireControl('ipad');
      return {
        'protocolVersion': 1,
        'commandId': 'live_${type.replaceAll('.', '_')}_${++commandSeq}',
        'hostSessionId': snapshot['hostSessionId'],
        'controlLeaseId': lease['controlLeaseId'],
        'expectedStateVersion': snapshot['stateVersion'],
        'expectedSceneRevision': snapshot['sceneRevision'],
        'type': type,
        'payload': payload
      };
    }

    test('advertise live control and route position into the live engine',
        () async {
      expect((liveCoordinator.snapshot()['capabilities'] as Map)['liveControl'],
          isTrue);
      final result = await liveCoordinator.command(
          'ipad',
          command('point.set',
              {'azimuthDeg': 60, 'elevationDeg': 10, 'distanceM': 2}));
      expect(result['status'], 'native_applied');
      expect(liveParams.single.azimuthDeg, closeTo(60, 1e-8));
      expect(controller.params.azimuthDeg, closeTo(60, 1e-8));
      expect(spatial.appliedRevision, 2);
    });

    test('route Original/Spatial into the live engine', () async {
      await liveCoordinator.command(
          'ipad', command('mode', {'mode': 'original'}));
      expect(liveModes, [PlaybackMode.original]);
    });

    test('media commands drive the Live source app only', () async {
      expect((liveCoordinator.snapshot()['capabilities'] as Map)['liveMedia'],
          isTrue);
      for (final type in [
        'media.pause',
        'media.play',
        'media.next',
        'media.previous'
      ]) {
        await liveCoordinator.command('ipad', command(type, const {}));
      }
      expect(mediaActions, ['pause', 'play', 'next', 'previous']);
      expect(liveParams, isEmpty);
      expect(liveModes, isEmpty);
    });

    test('a refused media command reports media_command_failed', () async {
      final failing = AppSessionCoordinator(
          controller: controller,
          spatial: spatial,
          nativeBackend: true,
          liveRunning: () => true,
          applyLiveParams: (params) async {},
          applyLiveMode: (mode) async {},
          liveMedia: (action) async => throw StateError('no next track'),
          now: () => now);
      addTearDown(failing.close);
      final snapshot = failing.snapshot();
      final lease = failing.acquireControl('ipad');
      await expectLater(
          failing.command('ipad', {
            'protocolVersion': 1,
            'commandId': 'media_fail',
            'hostSessionId': snapshot['hostSessionId'],
            'controlLeaseId': lease['controlLeaseId'],
            'expectedStateVersion': snapshot['stateVersion'],
            'expectedSceneRevision': snapshot['sceneRevision'],
            'type': 'media.next',
            'payload': const <String, dynamic>{}
          }),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'media_command_failed')));
    });

    test('media commands also work before Live starts', () async {
      live = false;
      await liveCoordinator.command('ipad', command('media.play', const {}));
      expect(mediaActions, ['play']);
    });

    test('remote start and stop Live through the hooks', () async {
      live = false;
      expect((liveCoordinator.snapshot()['capabilities'] as Map)['remoteLive'],
          isTrue);
      final started = await liveCoordinator.command(
          'ipad', command('live.start', const {}));
      expect(started['status'], 'native_applied');
      expect(liveCalls, ['start']);
      expect(live, isTrue);
      // Starting again while Live runs is a no-op.
      await liveCoordinator.command('ipad', command('live.start', const {}));
      expect(liveCalls, ['start']);
      await liveCoordinator.command('ipad', command('live.stop', const {}));
      expect(liveCalls, ['start', 'stop']);
      expect(live, isFalse);
    });

    test('start failures keep their reason; others become live_start_failed',
        () async {
      live = false;
      startFailure = const RemoteFailure('no_music_app');
      await expectLater(
          liveCoordinator.command('ipad', command('live.start', const {})),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'no_music_app')));
      startFailure = StateError('device lost');
      await expectLater(
          liveCoordinator.command('ipad', command('live.start', const {})),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'live_start_failed')));
      expect(live, isFalse);
    });

    test('Point/2.0 switch uses the hook and updates the 3D presentation',
        () async {
      var snap = liveCoordinator.snapshot();
      expect((snap['capabilities'] as Map)['remoteArray'], isTrue);
      expect((snap['spatialMode'] as Map)['array'], 'point');
      expect((snap['presentation'] as Map)['presentation'], 'point');

      await liveCoordinator.command(
          'ipad', command('array.mode', {'mode': 'stereo2'}));
      expect(arrayModes, [ArrayMode.stereo2]);
      snap = liveCoordinator.snapshot();
      expect((snap['spatialMode'] as Map)['array'], 'stereo2');
      expect((snap['presentation'] as Map)['presentation'], 'stereo2');
      expect((snap['presentation'] as Map)['arraySpeakers'], hasLength(2));
      expect((snap['capabilities'] as Map)['pointControl'], isFalse);

      await liveCoordinator.command(
          'ipad', command('array.mode', {'mode': 'point'}));
      snap = liveCoordinator.snapshot();
      expect((snap['spatialMode'] as Map)['array'], 'point');
      expect((snap['presentation'] as Map)['arraySpeakers'], isEmpty);
    });

    test('Orbit switch and speed reach the live engine; not in 2.0', () async {
      await liveCoordinator.command(
          'ipad', command('motion.set', {'motion': 'orbit', 'orbitHz': 0.8}));
      expect(liveParams.last.motion, MotionMode.orbit);
      expect(liveParams.last.orbitHz, closeTo(0.8, 1e-9));
      final mode = liveCoordinator.snapshot()['spatialMode'] as Map;
      expect(mode['motion'], 'orbit');
      expect(mode['orbitHz'], closeTo(0.8, 1e-9));

      await liveCoordinator.command(
          'ipad', command('motion.set', {'motion': 'fixed'}));
      expect(liveParams.last.motion, MotionMode.fixed);

      await liveCoordinator.command(
          'ipad', command('array.mode', {'mode': 'stereo2'}));
      await expectLater(
          liveCoordinator.command(
              'ipad', command('motion.set', {'motion': 'orbit'})),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'array_active')));
    });

    test('mode and orbit payloads are validated', () async {
      for (final bad in [
        ('array.mode', {'mode': 'quad'}),
        ('motion.set', {'motion': 'spin'}),
        ('motion.set', {'motion': 'orbit', 'orbitHz': 5}),
      ]) {
        await expectLater(
            liveCoordinator.command('ipad', command(bad.$1, bad.$2)),
            throwsA(isA<RemoteFailure>()
                .having((e) => e.code, 'code', 'invalid_payload')),
            reason: '${bad.$1} ${bad.$2}');
      }
      expect(arrayModes, isEmpty);
    });

    test('keep live transport on the laptop', () async {
      await expectLater(
          liveCoordinator.command('ipad', command('play', const {})),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'live_transport_on_laptop')));
      expect(liveParams, isEmpty);
    });

    test('without hooks live still refuses remote control', () {
      expect((coordinator.snapshot()['capabilities'] as Map)['liveControl'],
          isFalse);
      expect(() => coordinator.acquireControl('ipad'),
          throwsA(isA<RemoteFailure>()));
    });
  });
}
