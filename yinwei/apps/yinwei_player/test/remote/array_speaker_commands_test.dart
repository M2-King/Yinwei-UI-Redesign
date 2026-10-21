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
  late DateTime now;
  late String lease;
  final liveArrays = <ArrayLayout>[];
  var seq = 0;
  setUp(() async {
    engine = _Engine();
    c = EngineController(engine: engine);
    await c.applyArrayMode(ArrayMode.stereo2);
    live = false;
    liveSupported = true;
    now = DateTime(2026, 10, 21);
    liveArrays.clear();
    host = AppSessionCoordinator(
        controller: c,
        now: () => now,
        spatial: SpatialRuntimeAdapter()..bootstrap(c.params),
        nativeBackend: true,
        liveRunning: () => live,
        applyLiveParams: (_) async {},
        applyLiveMode: (_) async {},
        applyArrayMode: c.applyArrayMode,
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
      'type':
          type.startsWith('matrix.') ? 'array.$type' : 'array.speaker.$type',
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

  test('link captures rest at mean distance; unlink preserves every pose',
      () async {
    final local = c.array.copy()..addSpeaker(azimuthDeg: 170, elevationDeg: 20);
    local.speakers[0].distanceM = 2;
    local.speakers[1].distanceM = 4;
    local.speakers[2].distanceM = 6;
    await c.setArrayAcknowledged(local);
    host.snapshot();
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    await edit('matrix.link', values: {'linked': true});
    expect(c.array.matrixLinked, true);
    expect(c.array.matrixRest, hasLength(3));
    expect(c.array.speakers.map((s) => s.distanceM), [4, 4, 4]);
    final poses = (host.snapshot()['arrayState'] as Map)['speakers'];
    await edit('matrix.link', values: {'linked': false});
    expect(c.array.matrixLinked, false);
    expect(c.array.matrixRest, isNull);
    expect((host.snapshot()['arrayState'] as Map)['speakers'], poses);
  });

  test('linked gestures match laptop model and preserve spread and rest',
      () async {
    for (var i = 0; i < 6; i++) {
      await edit('add');
    }
    final local = c.array.copy()..setMatrixLinked(true);
    local.applyGroupDelta(azimuthDeltaDeg: 155, elevationDeltaDeg: 65);
    local.setMatrixSpread(1.7);
    await c.setArrayAcknowledged(local);
    host.snapshot();
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    final expected = local.copy();
    // Includes azimuth seam wrapping and elevation clamping.
    for (final pose in [
      {'az': -175.0, 'el': expected.selected.elevationDeg, 'dist': 1.8},
      {'az': -175.0, 'el': 85.0, 'dist': 1.8},
      {'az': -175.0, 'el': 85.0, 'dist': 4.2},
    ]) {
      expected.moveSelectedInGroup(
          azimuthDeg: pose['az'], elevationDeg: pose['el']);
      expected.setAllDistance(pose['dist']!);
      await edit('set', values: {'index': 7, ...pose});
      for (var i = 0; i < 8; i++) {
        expect(c.array.speakers[i].azimuthDeg, expected.speakers[i].azimuthDeg);
        expect(c.array.speakers[i].elevationDeg,
            expected.speakers[i].elevationDeg);
        expect(c.array.speakers[i].distanceM, expected.speakers[i].distanceM);
        expect(c.array.matrixRest![i].azimuthDeg,
            expected.matrixRest![i].azimuthDeg);
        expect(c.array.matrixRest![i].elevationDeg,
            expected.matrixRest![i].elevationDeg);
      }
      expect(c.array.matrixSpread, 1.7);
    }
    final rest = c.array.matrixRest!.map((s) => s.azimuthDeg).toList();
    await edit('matrix.link', values: {'linked': true});
    expect(c.array.matrixSpread, 1.7);
    expect(c.array.matrixRest!.map((s) => s.azimuthDeg), rest);
  });

  test('matrix command uses revision, deduplication, lease and takeover',
      () async {
    final request = input('matrix.link', values: {'linked': true});
    await host.command('ipad', request);
    final writes = engine.writes;
    await host.command('ipad', request);
    expect(engine.writes, writes);
    final oldRevision = (request['payload'] as Map)['arrayRevision'] as int;
    await expectLater(
        edit('matrix.link', revision: oldRevision, values: {'linked': false}),
        throwsA(code('stale_array')));
    await edit('set', values: {'index': 0, 'az': 70, 'el': 20, 'dist': 3});
    await expectLater(
        host.command('ipad', request), throwsA(code('stale_array')));
    final queued =
        host.command('ipad', input('matrix.link', values: {'linked': false}));
    host.takeLocalControl();
    await expectLater(queued, throwsA(code('control_lost')));
    expect(c.array.matrixLinked, true);
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    live = true;
    await edit('matrix.link', values: {'linked': false});
    expect(liveArrays.single.matrixLinked, false);
    for (final value in [null, 0, 'true']) {
      await expectLater(edit('matrix.link', values: {'linked': value}),
          throwsA(code('invalid_payload')));
    }
  });

  test('2.0 to Point and back retains linked array, spread and matrix rest',
      () async {
    await edit('add');
    await edit('matrix.link', values: {'linked': true});
    final before = c.array.copy();
    for (final mode in ['point', 'stereo2']) {
      final request = input('matrix.link');
      request['type'] = 'array.mode';
      request['payload'] = {'mode': mode};
      await host.command('ipad', request);
      expect(c.array.matrixLinked, true);
      expect(c.array.matrixSpread, before.matrixSpread);
      expect(c.array.speakers.map((s) => s.azimuthDeg),
          before.speakers.map((s) => s.azimuthDeg));
      expect(c.array.matrixRest!.map((s) => s.azimuthDeg),
          before.matrixRest!.map((s) => s.azimuthDeg));
    }
  });

  test('group sliders edit only their axis and leave laptop spread untouched',
      () async {
    final local = c.array.copy()
      ..setMatrixLinked(true)
      ..setMatrixSpread(1.7);
    // A laptop-added linked speaker starts at its own distance.
    local.speakers[1].distanceM = 4;
    local.matrixRest![1].distanceM = 4;
    await c.setArrayAcknowledged(local);
    host.snapshot();
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    final expected = local.copy();
    for (final entry in {'az': 170.0, 'el': 80.0, 'dist': 3.2}.entries) {
      if (entry.key == 'az') {
        expected.moveSelectedInGroup(azimuthDeg: entry.value);
      }
      if (entry.key == 'el') {
        expected.moveSelectedInGroup(elevationDeg: entry.value);
      }
      if (entry.key == 'dist') expected.setAllDistance(entry.value);
      await edit('matrix.set',
          values: {'index': 0, 'axis': entry.key, 'value': entry.value});
      for (var i = 0; i < 2; i++) {
        expect(c.array.speakers[i].azimuthDeg, expected.speakers[i].azimuthDeg);
        expect(c.array.speakers[i].elevationDeg,
            expected.speakers[i].elevationDeg);
        expect(c.array.speakers[i].distanceM, expected.speakers[i].distanceM);
        expect(c.array.matrixRest![i].distanceM,
            expected.matrixRest![i].distanceM);
      }
      expect(c.array.matrixSpread, 1.7);
    }
    for (final payload in [
      {'axis': 'spread', 'value': 1.2},
      {'axis': 'az', 'value': '50'},
      {'axis': 'el', 'value': 91},
      {'axis': 'dist', 'value': 0.4},
    ]) {
      await expectLater(edit('matrix.set', values: {'index': 0, ...payload}),
          throwsA(code('invalid_payload')));
    }
    final stale = (host.snapshot()['arrayState'] as Map)['revision'] as int;
    await edit('matrix.link', values: {'linked': false});
    await expectLater(
        edit('matrix.set',
            revision: stale, values: {'index': 0, 'axis': 'az', 'value': 50}),
        throwsA(code('stale_array')));
    await expectLater(
        edit('matrix.set', values: {'index': 0, 'axis': 'az', 'value': 50}),
        throwsA(code('matrix_inactive')));
  });

  test('expired matrix lease is rejected and renewed takeover succeeds',
      () async {
    now = now.add(const Duration(minutes: 2));
    await expectLater(edit('matrix.link', values: {'linked': true}),
        throwsA(code('control_lost')));
    expect(c.array.matrixLinked, false);
    lease = host.acquireControl('ipad')['controlLeaseId'] as String;
    await edit('matrix.link', values: {'linked': true});
    final request =
        input('matrix.set', values: {'index': 0, 'axis': 'az', 'value': 70});
    await host.command('ipad', request);
    final writes = engine.writes;
    await host.command('ipad', request);
    expect(engine.writes, writes);
    final queued = host.command('ipad',
        input('matrix.set', values: {'index': 0, 'axis': 'el', 'value': 30}));
    host.takeLocalControl();
    await expectLater(queued, throwsA(code('control_lost')));
    expect(c.array.selected.elevationDeg, 0);
  });

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
