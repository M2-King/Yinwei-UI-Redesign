// Regressions from the owner's iPad diagnostics, 2026-10-24 (build 66 / w32).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';
import 'package:yinwei_player/remote/soda_track_launcher.dart';

import 'listen_room_bridge_test.dart' show FakeSession, snapshot;

String _line(String status, double position, int updated) =>
    '{"status":"active","title":"U29uZw==","artist":"","album":"",'
    '"playbackStatus":"$status","position":$position,"duration":200,'
    '"updated":$updated,"source":"S","pid":1,"process":"SodaMusic"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Live song position', () {
    test('counts on from the app timestamp while playing', () {
      final s = SystemMediaService();
      final start = DateTime.now().millisecondsSinceEpoch - 90000;
      s.applyDaemonLine(_line('Playing', 0.1, start));
      final now = DateTime.fromMillisecondsSinceEpoch(start + 90000);
      expect(s.state.positionAt(now), closeTo(90.1, 0.01));
    });

    test('paused shows the reported position; clamps to the length', () {
      final s = SystemMediaService();
      final at = DateTime.now().millisecondsSinceEpoch - 500000;
      s.applyDaemonLine(_line('Paused', 42, at));
      expect(s.state.positionAt(DateTime.now()), 42);
      s.applyDaemonLine(_line('Playing', 42, at - 1));
      expect(s.state.positionAt(DateTime.now()), 200);
    });

    test('an unstamped resume never adds the paused time', () {
      final s = SystemMediaService();
      final at = DateTime.now().millisecondsSinceEpoch - 60000;
      s.applyDaemonLine(_line('Paused', 30, at));
      s.applyDaemonLine(_line('Playing', 30, at)); // same stamp: resume
      expect(s.state.positionAt(DateTime.now()), closeTo(30, 0.5));
    });

    test('no timestamp from an older daemon: the raw position', () {
      final s = SystemMediaService();
      s.applyDaemonLine(_line('Playing', 12, 0));
      expect(s.state.positionAt(DateTime.now()), 12);
    });
  });

  group('transport during a pending song tap', () {
    late FakeSession session;
    late ListenRoomBridge bridge;
    late List<String> scripts;
    setUp(() async {
      session = FakeSession()
        ..control = true
        ..snapshot = snapshot(liveRunning: true);
      session.snapshot!['capabilities']['liveMedia'] = true;
      session.snapshot!['live'] = {'playing': true};
      scripts = [];
      bridge = ListenRoomBridge(
          session: session, run: (script) async => scripts.add(script));
      bridge.attach();
      await bridge.handle('{"t":"ready"}');
      scripts.clear();
    });
    tearDown(() {
      bridge.dispose();
      session.dispose();
    });

    test('pause waits out a 5 s song handoff instead of being dropped',
        () async {
      session.pending = true;
      Future<void>.delayed(const Duration(seconds: 5), () {
        session.pending = false;
      });
      await bridge.handle('{"t":"media","a":"pause"}');
      expect(session.calls.where((c) => c.startsWith('media.pause')),
          hasLength(1));
      expect(scripts.where((s) => s.contains('commandRefused')), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('汽水 identity helper', () {
    test('a helper that cannot start falls back to the one-off reading',
        () async {
      var fallbacks = 0;
      final helper = SodaIdentityHelper(
          start: () async => throw const ProcessException('x', []),
          fallback: () async {
            fallbacks++;
            return (command: 'c', runningPaths: <String>['p']);
          });
      final value = await helper.inspect();
      expect(value.command, 'c');
      expect(fallbacks, 1);
    });

    test('parses the reading and refuses malformed output', () {
      final v = SodaTrackLauncher.parseIdentity(
          r'{"command":"x","runningPaths":["a",3]}');
      expect(v.runningPaths, ['a']);
      expect(() => SodaTrackLauncher.parseIdentity('error'),
          throwsA(isA<FormatException>()));
      expect(() => SodaTrackLauncher.parseIdentity('{"command":1}'),
          throwsA(isA<FormatException>()));
    });

    test('the ready PowerShell answers repeat readings fast (Windows)',
        () async {
      var fallbacks = 0;
      final helper = SodaIdentityHelper(fallback: () async {
        fallbacks++;
        return (command: '', runningPaths: <String>[]);
      });
      await helper.inspect(); // start-up
      final clock = Stopwatch()..start();
      for (var i = 0; i < 3; i++) {
        await helper.inspect();
      }
      final perRead = clock.elapsedMilliseconds / 3;
      // ignore: avoid_print
      print('SODA_IDENTITY_HELPER per-read ${perRead.toStringAsFixed(1)} ms');
      expect(fallbacks, 0);
      expect(perRead, lessThan(1500));
      // Same answer as the one-off reading it replaces.
      final fast = await helper.inspect(),
          slow = await SodaTrackLauncher.inspectOnce();
      expect(fast.command, slow.command);
      expect(fast.runningPaths.map((p) => p.toLowerCase()).toSet(),
          slow.runningPaths.map((p) => p.toLowerCase()).toSet());
    },
        skip: !Platform.isWindows,
        timeout: const Timeout(Duration(seconds: 60)));
  });
}
