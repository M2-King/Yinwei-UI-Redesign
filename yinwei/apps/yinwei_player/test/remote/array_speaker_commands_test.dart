import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _Engine extends MockEngine {
  Completer<void>? gate;
  int writes = 0;
  @override
  Future<void> setSpeakerCount(int n) async {
    writes++;
    await gate?.future;
  }
}

void main() {
  late _Engine engine;
  late EngineController c;
  late AppSessionCoordinator host;
  late bool live;
  late bool liveSupported;
  late String lease;
  final liveArrays = <ArrayLayout>[];
  var seq = 0;
  setUp(() async {
    engine = _Engine();
    c = EngineController(engine: engine);
    await c.applyArrayMode(ArrayMode.stereo2);
    live = false;
    liveSupported = true;
    liveArrays.clear();
    host = AppSessionCoordinator(
        controller: c,
        spatial: SpatialRuntimeAdapter()..bootstrap(c.params),
        nativeBackend: true,
        liveRunning: () => live,
        applyLiveParams: (_) async {},
        applyLiveMode: (_) async {},
        liveArraySpeakersAvailable: () => liveSupported,
        applyArrayLayout: (a) async {
          if (live) liveArrays.add(a.copy());
          await c.setArrayAcknowledged(a);
        });
    host.snapshot();
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
  });
  tearDown(() async {
    await host.close();
    c.dispose();
  });
  Map<String, dynamic> input(String type,
      {int? revision, Map<String, dynamic> values = const {}}) {
    final s = host.snapshot();
    return {
      'protocolVersion': 1,
      'hostSessionId': s['hostSessionId'],
      'commandId': 'array_command_${++seq}',
      'controlLeaseId': lease,
      'expectedStateVersion': s['stateVersion'],
      'expectedSceneRevision': s['sceneRevision'],
      'type': 'array.speaker.$type',
      'payload': {
        'arrayRevision': revision ?? (s['arrayState'] as Map)['revision'],
        ...values
      }
    };
  }

  Future<Map<String, dynamic>> edit(String type,
          {int? revision, Map<String, dynamic> values = const {}}) =>
      host.command('ipad', input(type, revision: revision, values: values));
  Matcher code(String code) =>
      isA<RemoteFailure>().having((e) => e.code, 'code', code);

  test('remove speaker 3 then retried old index 4 cannot edit shifted speaker',
      () async {
    for (var i = 0; i < 4; i++) {
      await edit('add');
    }
    final oldRevision =
        (host.snapshot()['arrayState'] as Map)['revision'] as int;
    await edit('remove', values: {'index': 2});
    final before = c.array.speakers[4].azimuthDeg;
    await expectLater(
        edit('set',
            revision: oldRevision,
            values: {'index': 4, 'az': 123, 'el': 0, 'dist': 2}),
        throwsA(code('stale_array')));
    expect(c.array.speakers[4].azimuthDeg, before);
  });

  test(
      'completed edit replay is rejected after removal instead of returning old array',
      () async {
    for (var i = 0; i < 4; i++) {
      await edit('add');
    }
    final oldEdit =
        input('set', values: {'index': 4, 'az': 60, 'el': 0, 'dist': 2});
    await host.command('ipad', oldEdit);
    await edit('remove', values: {'index': 2});
    final writes = engine.writes;
    await expectLater(
        host.command('ipad', oldEdit), throwsA(code('stale_array')));
    expect(engine.writes, writes);
    expect(c.array.speakers[4].azimuthDeg, 0);
  });

  test('every speaker command requires revision; count and L/R bounds enforced',
      () async {
    for (final type in ['add', 'remove', 'select', 'set']) {
      final request = input(type);
      (request['payload'] as Map).remove('arrayRevision');
      await expectLater(
          host.command('ipad', request), throwsA(code('stale_array')));
    }
    for (final index in [0, 1]) {
      await expectLater(edit('remove', values: {'index': index}),
          throwsA(code('speaker_protected')));
    }
    for (var i = 0; i < 6; i++) {
      await edit('add');
    }
    expect(c.array.speakers, hasLength(8));
    await expectLater(edit('add'), throwsA(code('speaker_limit')));
    await expectLater(
        edit('select', values: {'index': 8}), throwsA(code('invalid_payload')));
    await expectLater(
        edit('set', values: {'index': 2, 'az': 181, 'el': 0, 'dist': 2}),
        throwsA(code('invalid_payload')));
  });

  test(
      'matrix edits use cluster deltas, preserve audio properties and reach Live',
      () async {
    await edit('add');
    final local = c.array.copy()..setMatrixLinked(true);
    local.speakers[2].gainDb = -3;
    local.speakers[2].mute = true;
    await c.setArrayAcknowledged(local);
    host.snapshot();
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    live = true;
    await edit('set', values: {'index': 2, 'az': 40, 'el': 10, 'dist': 3});
    expect(c.array.speakers.map((s) => s.azimuthDeg), [10, 70, 40]);
    expect(
        c.array.speakers.every((s) => s.distanceM == 3 && s.elevationDeg == 10),
        true);
    expect(c.array.selected.gainDb, -3);
    expect(c.array.selected.mute, true);
    expect(liveArrays.single.speakers, hasLength(3));
    expect(liveArrays.single.selected.feed, SpeakerFeed.mid);
  });

  test(
      'remote edit waits for native completion; duplicate retry never writes twice',
      () async {
    engine.gate = Completer<void>();
    final request = input('add');
    var complete = false;
    final result = host.command('ipad', request)..then((_) => complete = true);
    await Future<void>.delayed(Duration.zero);
    expect(complete, false);
    engine.gate!.complete();
    expect((await result)['status'], 'native_applied');
    final writes = engine.writes;
    await host.command('ipad', request);
    expect(engine.writes, writes);
  });

  test(
      'laptop selection and gain/mute changes update revision and revoke lease',
      () async {
    await edit('add');
    final s = host.snapshot(device: 'ipad');
    expect((s['arrayState'] as Map)['selectedIndex'], 2);
    await c.selectArraySpeaker(0);
    final next = host.snapshot(device: 'ipad');
    expect((next['arrayState'] as Map)['revision'],
        greaterThan((s['arrayState'] as Map)['revision'] as int));
    expect(next['controlOwned'], false);
    await expectLater(
        edit('select', values: {'index': 1}), throwsA(code('control_lost')));
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    final a = c.array.copy();
    a.speakers[0].gainDb = -2;
    a.speakers[0].mute = true;
    await c.setArrayAcknowledged(a);
    final changed = host.snapshot(device: 'ipad');
    expect(changed['controlOwned'], false);
    expect(((changed['arrayState'] as Map)['speakers'] as List).first['mute'],
        true);
  });

  test('queued command loses lease to laptop; unsupported Live never edits',
      () async {
    final result = host.command('ipad', input('add'));
    host.takeLocalControl();
    await expectLater(result, throwsA(code('control_lost')));
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    live = true;
    liveSupported = false;
    expect((host.snapshot()['capabilities'] as Map)['remoteSpeakers'], false);
    await expectLater(edit('add'), throwsA(code('unsupported_command')));
    expect(c.array.speakers, hasLength(2));
  });
}
