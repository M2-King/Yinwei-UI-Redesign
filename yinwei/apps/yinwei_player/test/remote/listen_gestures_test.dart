import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_gestures.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';

import 'listen_room_bridge_test.dart' as room;

class _Store implements GestureSettingsStore {
  Map<String, bool> value = {};
  @override
  Future<Map<String, bool>> load() async => Map.of(value);
  @override
  Future<void> save(Map<String, bool> next) async => value = Map.of(next);
}

Map<String, Object?> frame([double t = 100]) => {
      't': t,
      'event': 'Open_Palm',
      'latencyMs': 198.0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(ListenGestures.channelName);
  late StreamController<Object?> events;
  late _Store store;
  late ListenGestures gestures;
  late List<String> calls;
  late List<Map<String, Object?>> frames;
  Future<Map<String, Object?>> Function()? start;
  Future<Object?> Function(String)? nativeResult;

  setUp(() {
    events = StreamController<Object?>.broadcast(sync: true);
    store = _Store();
    calls = [];
    frames = [];
    start = null;
    nativeResult = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      if (call.method == 'permission') return 'granted';
      if (call.method == 'clock' || call.method == 'configure') {
        return nativeResult == null ? 50.0 : await nativeResult!(call.method);
      }
      if (call.method == 'start') {
        return await start?.call() ?? {'permission': 'granted', 'active': true};
      }
      return null;
    });
    gestures =
        ListenGestures(store: store, methods: methods, events: events.stream)
          ..onResult = frames.add;
    gestures.setContext(ready: true, foreground: true, available: true);
  });
  tearDown(() async {
    gestures.dispose();
    await events.close();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
  });

  Future<void> enable() async {
    await gestures.initialize();
    await gestures.acceptConsent();
    await gestures.setEnabled(true);
  }

  test('defaults off; permission inspection never starts the camera', () async {
    await gestures.initialize();
    expect(gestures.enabled, false);
    expect(gestures.consent, false);
    expect(calls, ['permission']);
    await gestures.setEnabled(true);
    events.add(frame());
    expect(frames, isEmpty);
    expect(calls, ['permission']);
  });
  test('consent and on/off persist; restored on still needs a new opt-in tap',
      () async {
    await enable();
    expect(store.value, {'on': true, 'consent': true});
    final restored =
        ListenGestures(store: store, methods: methods, events: events.stream);
    await restored.initialize();
    expect(restored.enabled, true);
    expect(restored.consent, true);
    expect(restored.active, false);
    restored.dispose();
    await gestures.setEnabled(false);
    expect(store.value, {'on': false, 'consent': true});
    expect(calls, contains('stop'));
  });
  test('only validated frames arrive while on, ready and foreground', () async {
    events.add(frame());
    expect(frames, isEmpty);
    await enable();
    events.add(frame());
    expect(frames, hasLength(1));
    gestures.setContext(ready: true, foreground: false, available: true);
    events.add(frame(200));
    expect(frames, hasLength(1));
    gestures.setContext(ready: true, foreground: true, available: true);
    events.add(frame(300));
    expect(frames, hasLength(1));
    expect(gestures.active, false);
    await gestures.setEnabled(true);
    events.add(frame(400));
    expect(frames, hasLength(2));
    gestures.setContext(ready: false, foreground: true, available: true);
    events.add(frame(500));
    expect(frames, hasLength(2));
  });
  test('off immediately stops native and drops frames', () async {
    await enable();
    await gestures.setEnabled(false);
    events.add(frame());
    expect(frames, isEmpty);
    expect(gestures.active, false);
    expect(calls.last, 'stop');
  });
  test('late camera permission completion cannot reactivate after off',
      () async {
    await gestures.acceptConsent();
    final gate = Completer<Map<String, Object?>>();
    start = () => gate.future;
    final pending = gestures.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(gestures.starting, true);
    await gestures.setEnabled(false);
    gate.complete({'permission': 'granted', 'active': true});
    await pending;
    events.add(frame());
    expect(gestures.active, false);
    expect(gestures.starting, false);
    expect(frames, isEmpty);
  });
  test('native interruption stops without automatically resuming', () async {
    await enable();
    events.add({'state': 'stopped', 'permission': 'granted'});
    events.add(frame());
    expect(frames, isEmpty);
    expect(gestures.active, false);
    expect(gestures.enabled, true);
  });
  test('denied permission is reported and never forwards a frame', () async {
    start = () async => {'permission': 'denied', 'active': false};
    await enable();
    events.add(frame());
    expect(gestures.permission, 'denied');
    expect(gestures.error, contains('Settings'));
    expect(frames, isEmpty);
  });
  test(
      'decisions have no frame throttle and reject duplicate or backwards time',
      () async {
    await enable();
    for (final t in [100.0, 100.0, 90.0, 120.0, 149.0, 150.0, 200.0]) {
      events.add(frame(t));
    }
    expect(frames.map((f) => f['t']), [100, 120, 149, 150, 200]);
  });
  test('decision fields are clamped and whitelisted; frames never cross', () {
    expect(
        ListenGestures.sanitize({
          ...frame(),
          't': -1,
          'latencyMs': 99999,
          'pixels': [1],
          'x': 1
        }),
        {'event': 'Open_Palm', 't': 0.0, 'latencyMs': 10000.0});
    expect(
        ListenGestures.sanitize({
          't': 1,
          'hand': true,
          'g': 'Open_Palm',
          'score': 1,
          'x': 0.5,
          'y': 0.5,
          's': 0.12
        }),
        isNull);
    expect(
        ListenGestures.sanitize({
          't': 1,
          'pose': null,
          'progress': 4,
          'strokes': [],
          'pixels': 'discard'
        }),
        {'t': 1.0, 'pose': null, 'progress': 1.0, 'strokes': []});
  });
  test('malformed decisions and status are ignored', () {
    for (final value in [
      null,
      'frame',
      {},
      {...frame(), 'event': 'other'},
      {...frame(), 'latencyMs': double.nan},
      {...frame(), 't': double.infinity},
      {...frame(), 't': '100'},
      {'t': 1, 'pose': 'other', 'progress': 1}
    ]) {
      expect(ListenGestures.sanitize(value), isNull);
    }
  });
  test('status and a decision at the same timestamp are both delivered',
      () async {
    await enable();
    events.add({'t': 100, 'pose': 'Open_Palm', 'progress': 0.5, 'strokes': []});
    events.add(frame(100));
    events.add(frame(100));
    expect(frames, hasLength(2));
  });
  test('numeric calibration summaries are bounded and never include joints',
      () {
    final status = ListenGestures.sanitize({
      't': 1,
      'pose': null,
      'progress': 0,
      'strokes': [
        {
          't': 0,
          'event': 'swipeLeft',
          'travel': 0.5,
          'peak': 4,
          'ratio': 3,
          'gap': null,
          'fired': true,
          'joints': [1]
        },
        {
          't': 0,
          'event': 'other',
          'travel': 1,
          'peak': 2,
          'ratio': 3,
          'fired': false
        }
      ]
    })!;
    final strokes = status['strokes'] as List;
    expect(strokes, hasLength(1));
    expect((strokes.first as Map).containsKey('joints'), false);
  });
  test('old calibration is ignored and new thresholds cannot be stricter', () {
    expect(
        ListenGestures.tuning({'swipeHands': 0}), ListenGestures.tuning(null));
    final tuned = ListenGestures.tuning({
      'version': 2,
      'commitHands': 99,
      'swipeSpeed': double.nan,
      'rearmMs': 0,
      'returnMs': 0
    });
    expect(tuned['commitHands'], 0.34);
    expect(tuned['swipeSpeed'], 2.4);
    expect(tuned['rearmMs'], 100);
    expect(tuned['returnMs'], 0);
  });
  test(
      'configuration and clock never open the camera and require an active context',
      () async {
    expect(await gestures.configure({'version': 2}), isNull);
    expect(await gestures.clock(), isNull);
    await enable();
    expect(await gestures.configure({'version': 2}), 50);
    expect(await gestures.clock(), 50);
    gestures.setContext(ready: true, foreground: false, available: true);
    final before = calls.length;
    expect(await gestures.configure({'version': 2}), isNull);
    expect(await gestures.clock(), isNull);
    expect(calls.length, before);
  });
  test('diagnostics keep numeric aggregates only', () {
    expect(
        ListenGestures.metrics({
          'Open_Palm': {
            'count': 1,
            'decisionP50': 198,
            'pixels': [1],
            'deliveryP95': double.nan
          },
          'other': {'count': 1}
        }),
        {
          'Open_Palm': {'count': 1.0, 'decisionP50': 198.0}
        });
  });
  test('native configuration failure stops the camera and does not resume',
      () async {
    await enable();
    nativeResult = (_) async => throw PlatformException(code: 'native_lost');
    expect(await gestures.configure({'version': 2}), isNull);
    expect(gestures.active, false);
    events.add(frame());
    expect(frames, isEmpty);
    expect(calls, contains('stop'));
  });
  test('a late clock reply cannot survive a background transition', () async {
    await enable();
    final pending = Completer<Object?>();
    nativeResult = (_) => pending.future;
    final reply = gestures.clock();
    gestures.setContext(ready: true, foreground: false, available: true);
    pending.complete(200);
    expect(await reply, isNull);
  });
  test('Copy audio diagnostics includes only sanitized gesture aggregates',
      () async {
    final session = room.FakeSession()..snapshot = room.snapshot();
    final bridge = ListenRoomBridge(
        session: session, gestures: gestures, run: (_) async {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<String, dynamic>? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = jsonDecode((call.arguments as Map)['text'] as String)
            as Map<String, dynamic>;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    bridge.attach();
    await bridge.handle('{"t":"ready"}');
    await bridge.handle(
        '{"t":"gestureMetrics","metrics":{"swipeLeft":{"count":2,"decisionP50":66,"deliveryP95":8,"pixels":[1]},"unknown":{"count":8}}}');
    await bridge.handle('{"t":"copyAudioDiagnostics"}');
    expect(copied?['gestures'], {
      'swipeLeft': {'count': 2.0, 'decisionP50': 66.0, 'deliveryP95': 8.0}
    });
    expect(session.calls, isEmpty);
    bridge.dispose();
    session.dispose();
  });
  test('file preferences round-trip locally and corrupt content defaults off',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('yinwei-gesture-settings-');
    try {
      final files =
          FileGestureSettingsStore(directoryProvider: () async => directory);
      expect(await files.load(), {'on': false, 'consent': false});
      await files.save({'on': true, 'consent': true});
      expect(await files.load(), {'on': true, 'consent': true});
      await File('${directory.path}/listen_gestures.json')
          .writeAsString('{bad');
      expect(await files.load(), {'on': false, 'consent': false});
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('bridge sends frames only to the page, never the laptop', () async {
    final session = room.FakeSession()..snapshot = room.snapshot();
    final scripts = <String>[];
    final bridge = ListenRoomBridge(
        session: session, gestures: gestures, run: (s) async => scripts.add(s));
    bridge.attach();
    await bridge.handle('{"t":"ready"}');
    await bridge.handle('{"t":"gestureConsent"}');
    await bridge.handle('{"t":"gestures","on":true}');
    events.add(frame());
    expect(scripts.where((s) => s.startsWith('YinweiListen.handResult(')),
        hasLength(1));
    final raw =
        scripts.firstWhere((s) => s.startsWith('YinweiListen.handResult('));
    expect(
        jsonDecode(
            raw.substring('YinweiListen.handResult('.length, raw.length - 1)),
        frame());
    expect(session.calls, isEmpty);
    bridge.background = true;
    events.add(frame(200));
    bridge.background = false;
    expect(gestures.active, false);
    await bridge.handle('{"t":"gestures","on":true}');
    session.set((s) => s.interrupted = true);
    events.add(frame(300));
    expect(gestures.active, false);
    expect(session.calls, isEmpty);
    bridge.dispose();
    session.dispose();
  });
  test('close, sign-out and reload each stop the camera immediately', () async {
    for (final operation in ['close', 'signOut', 'reload']) {
      final local =
          ListenGestures(store: store, methods: methods, events: events.stream);
      final session = room.FakeSession()..snapshot = room.snapshot();
      final bridge = ListenRoomBridge(
          session: session, gestures: local, run: (_) async {});
      bridge.attach();
      await bridge.handle('{"t":"ready"}');
      await bridge.handle('{"t":"gestureConsent"}');
      await bridge.handle('{"t":"gestures","on":true}');
      expect(local.active, true);
      if (operation == 'reload') {
        bridge.pageReloaded();
      } else {
        await bridge.handle('{"t":"$operation"}');
      }
      expect(local.active, false);
      bridge.dispose();
      session.dispose();
    }
  });

  test('Runner camera sources and privacy text are wired into the build', () {
    final project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final ids =
        RegExp(r'^\s*([A-F0-9]{24})\s*/\*.*?\*/\s*=\s*\{', multiLine: true)
            .allMatches(project)
            .map((m) => m[1]!)
            .toList();
    expect(ids.toSet(), hasLength(ids.length),
        reason: 'new feature IDs cannot shadow existing native sources');
    for (final name in [
      'YinweiHandPose.swift',
      'YinweiHandGestures.swift',
      'YinweiGestureEngine.swift'
    ]) {
      expect(RegExp(RegExp.escape('$name in Sources')).allMatches(project),
          hasLength(2));
      expect(project, contains('path = $name;'));
    }
    expect(File('ios/Runner/AppDelegate.swift').readAsStringSync(),
        contains('YinweiHandGestures.register(messenger: messenger)'));
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>NSCameraUsageDescription</key>'));
    expect(
        plist,
        contains(
            'Yinwei uses the front camera only while hand gestures are on, to see your hand. Video stays on this iPad and is never saved or sent.'));
    expect(File('../../tools/test_ios_capture.sh').readAsStringSync(),
        contains('test/native_gestures/main.swift'));
  });

  test('a slow page preserves decisions in order without blocking audio',
      () async {
    final session = room.FakeSession()..snapshot = room.snapshot();
    final gate = Completer<void>();
    var delivered = 0;
    final bridge = ListenRoomBridge(
        session: session,
        gestures: gestures,
        run: (script) async {
          if (script.startsWith('YinweiListen.handResult(')) {
            delivered++;
            await gate.future;
          }
        });
    bridge.attach();
    await bridge.handle('{"t":"ready"}');
    await bridge.handle('{"t":"gestureConsent"}');
    await bridge.handle('{"t":"gestures","on":true}');
    events.add(frame(100));
    events.add(frame(200));
    expect(delivered, 1);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    events.add(frame(300));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, 3);
    bridge.dispose();
    session.dispose();
  });

  test('losing the web process stops the camera and waits for ready again',
      () async {
    final session = room.FakeSession()..snapshot = room.snapshot();
    final bridge = ListenRoomBridge(
        session: session,
        gestures: gestures,
        run: (script) async {
          if (script.startsWith('YinweiListen.handResult(')) {
            throw StateError('page gone');
          }
        });
    bridge.attach();
    await bridge.handle('{"t":"ready"}');
    await bridge.handle('{"t":"gestureConsent"}');
    await bridge.handle('{"t":"gestures","on":true}');
    events.add(frame());
    await Future<void>.delayed(Duration.zero);
    expect(bridge.ready, false);
    expect(gestures.active, false);
    expect(calls, contains('stop'));
    expect(session.calls, isEmpty);
    bridge.dispose();
    session.dispose();
  });

  test(
      'native camera seam has no audio writes, microphone, file or network API',
      () {
    final source =
        File('ios/Runner/YinweiHandGestures.swift').readAsStringSync();
    for (final protected in [
      'setCategory(',
      'setMode(',
      'setActive(',
      'for: .audio',
      'URLSession',
      'AVAssetWriter',
      'UIImage',
      'writeToFile'
    ]) {
      expect(source, isNot(contains(protected)));
    }
    expect(source, isNot(contains('recognizedPoints(.all)')));
    expect(source, isNot(contains('lastAnalysis')));
    for (final required in [
      'automaticallyConfiguresApplicationAudioSession = false',
      'usesApplicationAudioSession = false',
      'alwaysDiscardsLateVideoFrames = true',
      'maximumHandCount = 1',
      'qos: .utility',
      'CMSampleBufferGetPresentationTimeStamp',
      'CMSyncConvertTime',
      'engine.feed(t: t, pose: pose)',
      'UIApplication.didEnterBackgroundNotification',
      'AVAudioSession.interruptionNotification'
    ]) {
      expect(source, contains(required));
    }
  });
}
