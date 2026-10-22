import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

void main() {
  late EngineController engine;
  late AppSessionCoordinator host;
  late int dispatches, reads;
  Completer<void>? gate;
  setUp(() {
    dispatches = 0;
    reads = 0;
    gate = null;
    engine = EngineController(engine: MockEngine());
    host = AppSessionCoordinator(
        controller: engine,
        spatial: SpatialRuntimeAdapter()..bootstrap(engine.params),
        nativeBackend: true,
        liveRunning: () => true,
        applyLiveParams: (_) async {},
        applyLiveMode: (_) async {},
        sodaMetadata: (kind, payload) async {
          reads++;
          await gate?.future;
          return {'kind': kind, 'revision': 'opaque_revision', 'rows': []};
        },
        sodaPlay: (payload, guard) async {
          await gate?.future;
          if (payload.length != 2 ||
              payload['track'] != 'opaque_track' ||
              payload['revision'] != 'opaque_revision') {
            throw const RemoteFailure('soda_stale_selection');
          }
          guard();
          dispatches++;
        });
  });
  tearDown(() async {
    await host.close();
    engine.dispose();
  });
  Map<String, dynamic> read() => {
        'commandId': 'online_read_001',
        'protocolVersion': 1,
        'hostSessionId': host.hostSessionId,
        'type': 'soda.search',
        'payload': {'query': 'rain'}
      };
  Map<String, dynamic> play() {
    final lease = host.acquireControl('ipad');
    final s = host.snapshot();
    return {
      'commandId': 'online_play_001',
      'protocolVersion': 1,
      'hostSessionId': host.hostSessionId,
      'controlLeaseId': lease['controlLeaseId'],
      'expectedStateVersion': s['stateVersion'],
      'expectedSceneRevision': s['sceneRevision'],
      'type': 'soda.play',
      'payload': {'track': 'opaque_track', 'revision': 'opaque_revision'}
    };
  }

  Matcher code(String v) =>
      isA<RemoteFailure>().having((e) => e.code, 'code', v);
  test(
      'read-only commands use existing endpoint semantics without taking a lease',
      () async {
    host.takeLocalControl();
    final input = read();
    expect((await host.command('ipad', input))['status'], 'read');
    await host.command('ipad', input);
    expect(reads, 2);
    expect(dispatches, 0);
    expect(host.snapshot(device: 'ipad')['controlOwned'], false);
    await expectLater(host.command('ipad', {...input, 'hostSessionId': 'old'}),
        throwsA(code('stale_host')));
    expect(reads, 2);
  });
  test('host closure fences in-flight metadata responses', () async {
    gate = Completer<void>();
    final pending = host.command('ipad', read());
    await Future<void>.delayed(Duration.zero);
    await host.close();
    final check = expectLater(pending, throwsA(code('host_closed')));
    gate!.complete();
    await check;
  });
  test('online playback uses the same Live lease and command-ID dedupe',
      () async {
    final input = play();
    gate = Completer<void>();
    final first = host.command('ipad', input);
    final retry = host.command('ipad', input);
    gate!.complete();
    expect((await first)['status'], 'submitted');
    await retry;
    await host.command('ipad', input);
    expect(dispatches, 1);
    expect(
        () => host.command('ipad', {
              ...input,
              'payload': {'track': 'other'}
            }),
        throwsA(code('command_id_reused')));
  });
  test('takeover while resolving prevents external dispatch', () async {
    final input = play();
    gate = Completer<void>();
    final pending = host.command('ipad', input);
    await Future<void>.delayed(Duration.zero);
    host.takeLocalControl();
    final check = expectLater(pending, throwsA(code('control_lost')));
    gate!.complete();
    await check;
    expect(dispatches, 0);
  });
  test('raw IDs and wrong revisions are refused before dispatch', () async {
    final input = play();
    input['payload'] = {'track': '7399000000000000001', 'revision': 'old'};
    await expectLater(
        host.command('ipad', input), throwsA(code('soda_stale_selection')));
    expect(dispatches, 0);
  });
  test('default host does not advertise online integration', () async {
    final other = AppSessionCoordinator(
        controller: engine,
        spatial: SpatialRuntimeAdapter()..bootstrap(engine.params),
        nativeBackend: true,
        liveRunning: () => false);
    expect((other.snapshot()['capabilities'] as Map)['sodaOnline'], false);
    expect((other.snapshot()['capabilities'] as Map)['sodaOnlinePlay'], false);
    await other.close();
  });
}
