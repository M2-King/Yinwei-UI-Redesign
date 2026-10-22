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
  late Completer<void>? resolution;
  late int submitted;
  late DateTime now;

  setUp(() {
    submitted = 0;
    resolution = null;
    now = DateTime(2026, 10, 21);
    engine = EngineController(engine: MockEngine());
    host = AppSessionCoordinator(
        controller: engine,
        spatial: SpatialRuntimeAdapter()..bootstrap(engine.params),
        nativeBackend: true,
        now: () => now,
        liveRunning: () => true,
        libraryList: (_) async => {'revision': 'catalog_v1', 'lists': []},
        applyLiveParams: (_) async {},
        applyLiveMode: (_) async {},
        libraryPlay: (payload, beforeDispatch) async {
          await resolution?.future;
          if (payload['track'] != 'host_track') {
            throw const RemoteFailure('soda_invalid_selection');
          }
          beforeDispatch();
          submitted++;
        });
  });
  tearDown(() async {
    await host.close();
    engine.dispose();
  });

  Map<String, dynamic> command({String id = 'soda_command_001'}) {
    final lease = host.acquireControl('ipad');
    final snapshot = host.snapshot();
    return {
      'protocolVersion': 1,
      'commandId': id,
      'hostSessionId': snapshot['hostSessionId'],
      'controlLeaseId': lease['controlLeaseId'],
      'expectedStateVersion': snapshot['stateVersion'],
      'expectedSceneRevision': snapshot['sceneRevision'],
      'type': 'library.play',
      'payload': {
        'list': 'liked',
        'snapshot': 'host_snapshot',
        'track': 'host_track'
      }
    };
  }

  Matcher code(String value) =>
      isA<RemoteFailure>().having((error) => error.code, 'code', value);

  test(
      'allowed during Live; identical in-flight and completed retries submit once',
      () async {
    expect((host.snapshot()['capabilities'] as Map)['sodaLibrary'], isTrue);
    final input = command();
    resolution = Completer<void>();
    final first = host.command('ipad', input);
    final repeated = host.command('ipad', input);
    resolution!.complete();
    final results = await Future.wait([first, repeated]);
    expect(submitted, 1);
    expect(results.first['status'], 'submitted');
    expect(await host.command('ipad', input), results.first);
    expect(submitted, 1);
  });
  test(
      'library.list needs no lease and retries re-read the account-bound catalog',
      () async {
    host.takeLocalControl();
    final input = {
      'protocolVersion': 1,
      'hostSessionId': host.hostSessionId,
      'commandId': 'library_read_001',
      'type': 'library.list',
      'payload': <String, dynamic>{}
    };
    expect((await host.command('reader', input))['library']['revision'],
        'catalog_v1');
    expect((await host.command('reader', input))['status'], 'read');
    expect(submitted, 0);
    expect(host.snapshot(device: 'reader')['controlOwned'], false);
    await expectLater(
        host.command('reader', {...input, 'hostSessionId': 'old_host'}),
        throwsA(code('stale_host')));
    await expectLater(
        host.command('reader', {
          ...input,
          'payload': {'url': 'untrusted'}
        }),
        throwsA(code('invalid_payload')));
  });

  test('search travels as library.list with a query, advertised separately',
      () async {
    final caps = host.snapshot()['capabilities'] as Map;
    expect(caps['sodaSearch'], isTrue);
    final payloads = <Map<String, dynamic>>[];
    final searching = AppSessionCoordinator(
        controller: engine,
        spatial: SpatialRuntimeAdapter()..bootstrap(engine.params),
        nativeBackend: true,
        liveRunning: () => true,
        applyLiveParams: (_) async {},
        applyLiveMode: (_) async {},
        libraryList: (payload) async {
          payloads.add(payload);
          return {'revision': 'catalog_v1', 'lists': [], 'search': {}};
        },
        libraryPlay: (_, __) async {});
    addTearDown(searching.close);
    final read = await searching.command('reader', {
      'protocolVersion': 1,
      'hostSessionId': searching.hostSessionId,
      'commandId': 'library_find_001',
      'type': 'library.list',
      'payload': {'query': 'rain'}
    });
    expect(read['status'], 'read');
    expect(payloads.single, {'query': 'rain'});
  });

  test('same command ID with another selection is rejected', () async {
    final input = command();
    await host.command('ipad', input);
    await expectLater(
        Future.sync(() => host.command('ipad', {
              ...input,
              'payload': {'track': 'other'}
            })),
        throwsA(code('command_id_reused')));
    expect(submitted, 1);
  });

  test('foreign opaque selection is rejected without dispatch', () async {
    final input = command();
    input['payload'] = {'track': 'foreign'};
    await expectLater(
        host.command('ipad', input), throwsA(code('soda_invalid_selection')));
    expect(submitted, 0);
  });

  test('takeover during catalog preparation prevents external dispatch',
      () async {
    final input = command();
    resolution = Completer<void>();
    final pending = host.command('ipad', input);
    final expectation = expectLater(pending, throwsA(code('control_lost')));
    await Future<void>.delayed(Duration.zero);
    host.takeLocalControl();
    resolution!.complete();
    await expectation;
    expect(submitted, 0);
  });

  test('lease expiring during preparation prevents dispatch', () async {
    final input = command();
    resolution = Completer<void>();
    final pending = host.command('ipad', input);
    final expectation = expectLater(pending, throwsA(code('control_lost')));
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 31));
    resolution!.complete();
    await expectation;
    expect(submitted, 0);
  });

  test('another device cannot dispatch using the owner device lease', () async {
    await expectLater(
        host.command('other_ipad', command()), throwsA(code('control_lost')));
    expect(submitted, 0);
  });
}
