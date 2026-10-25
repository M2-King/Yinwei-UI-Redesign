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
      'hand': true,
      'g': 'Open_Palm',
      'score': 0.9,
      'x': 0.5,
      'y': 0.4,
      's': 0.15,
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

  setUp(() {
    events = StreamController<Object?>.broadcast(sync: true);
    store = _Store();
    calls = [];
    frames = [];
    start = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      if (call.method == 'permission') return 'granted';
      if (call.method == 'start') {
        return await start?.call() ?? {'permission': 'granted', 'active': true};
      }
      return null;
    });
    gestures =
        ListenGestures(store: store, methods: methods, events: events.stream)
          ..onFrame = frames.add;
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
  test('throttle is at most 20 fps and rejects backwards or duplicate time',
      () async {
    await enable();
    for (final t in [100.0, 100.0, 90.0, 120.0, 149.0, 150.0, 200.0]) {
      events.add(frame(t));
    }
    expect(frames.map((f) => f['t']), [100, 150, 200]);
  });
  test('clamps finite numbers and whitelists fields; never forwards images',
      () {
    final clean = ListenGestures.sanitize({
      ...frame(),
      't': -1,
      'x': 4,
      'y': -2,
      'score': 3,
      's': 99,
      'pixels': [1, 2]
    })!;
    expect(clean['t'], 0);
    expect(clean['x'], 1);
    expect(clean['y'], 0);
    expect(clean['score'], 1);
    expect(clean['s'] as double, closeTo(5 / 3, 1e-9));
    expect(clean.keys,
        unorderedEquals(['t', 'hand', 'g', 'score', 'x', 'y', 's']));
    expect(
        ListenGestures.sanitize({'t': 1, 'hand': false, 'pixels': 'discard'}),
        {'t': 1.0, 'hand': false});
  });
  test('malformed, unknown gesture and nonfinite frames are ignored', () {
    for (final bad in [
      null,
      'frame',
      {},
      {...frame(), 'hand': 1},
      {...frame(), 'g': 'other'},
      {...frame(), 'x': double.nan},
      {...frame(), 's': double.infinity},
      {...frame(), 't': '100'}
    ]) {
      expect(ListenGestures.sanitize(bad), isNull);
    }
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
    expect(scripts.where((s) => s.startsWith('YinweiListen.handFrame(')),
        hasLength(1));
    final raw =
        scripts.firstWhere((s) => s.startsWith('YinweiListen.handFrame('));
    expect(
        jsonDecode(
            raw.substring('YinweiListen.handFrame('.length, raw.length - 1)),
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
    for (final name in ['YinweiHandPose.swift', 'YinweiHandGestures.swift']) {
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

  test('a slow page drops new frames instead of queuing work behind audio',
      () async {
    final session = room.FakeSession()..snapshot = room.snapshot();
    final gate = Completer<void>();
    var delivered = 0;
    final bridge = ListenRoomBridge(
        session: session,
        gestures: gestures,
        run: (script) async {
          if (script.startsWith('YinweiListen.handFrame(')) {
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
    expect(delivered, 2);
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
          if (script.startsWith('YinweiListen.handFrame(')) {
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
    for (final required in [
      'automaticallyConfiguresApplicationAudioSession = false',
      'usesApplicationAudioSession = false',
      'alwaysDiscardsLateVideoFrames = true',
      'maximumHandCount = 1',
      'qos: .utility',
      't - lastAnalysis >= 50',
      'UIApplication.didEnterBackgroundNotification',
      'AVAudioSession.interruptionNotification'
    ]) {
      expect(source, contains(required));
    }
  });
}
