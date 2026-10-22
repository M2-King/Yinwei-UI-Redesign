import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/soda_track_launcher.dart';

void main() {
  final executable =
      '${Directory.systemTemp.path}${Platform.pathSeparator}SodaMusic.exe';
  final command = '"$executable" "--" "%1"';
  Matcher code(String value) =>
      isA<RemoteFailure>().having((error) => error.code, 'code', value);

  test('constructs one track-only URI and guards immediately before dispatch',
      () async {
    final events = <String>[];
    final launcher = SodaTrackLauncher(
      supported: true,
      exists: (_) => true,
      inspect: () async {
        events.add('inspect');
        return (command: command, runningPaths: [executable]);
      },
      launch: (path, args) async {
        events.add('dispatch');
        expect(path, executable);
        expect(args.first, '--');
        final uri = Uri.parse(args.last);
        expect(uri.scheme, 'luna');
        expect(uri.host, 'luna.com');
        expect(uri.path, '/playing');
        expect(uri.queryParameters,
            {'track_id': '1234567890', 'media_type': 'track'});
      },
    );
    await launcher.play('1234567890',
        revalidateSelection: () async => events.add('revalidate'),
        beforeDispatch: () => events.add('guard'));
    expect(events, ['inspect', 'revalidate', 'guard', 'dispatch']);
  });

  test('account or catalog change during handler inspection prevents dispatch',
      () async {
    var dispatched = false, guarded = false;
    final launcher = SodaTrackLauncher(
        supported: true,
        exists: (_) => true,
        inspect: () async => (command: command, runningPaths: [executable]),
        launch: (_, __) async {
          dispatched = true;
        });
    await expectLater(
        launcher.play('123', beforeDispatch: () {
          guarded = true;
        }, revalidateSelection: () async {
          throw const RemoteFailure('soda_stale_selection');
        }),
        throwsA(code('soda_stale_selection')));
    expect(dispatched, false);
    expect(guarded, false);
  });

  for (final unsafe in [
    '123&media_type=video',
    'luna://luna.com/playing',
    '1;anything',
    '',
    '123\n456'
  ]) {
    test('rejects non-catalog track ID $unsafe without inspecting or launching',
        () async {
      var called = false;
      final launcher = SodaTrackLauncher(
          supported: true,
          inspect: () async {
            called = true;
            return (command: command, runningPaths: [executable]);
          });
      await expectLater(launcher.play(unsafe, beforeDispatch: () {}),
          throwsA(code('soda_invalid_selection')));
      expect(called, isFalse);
    });
  }

  for (final unsafe in [
    '"$executable" -- "%1"',
    '"$executable" "--" "%1" --inspect',
    '"${Directory.systemTemp.path}${Platform.pathSeparator}other.exe" "--" "%1"',
    '"SodaMusic.exe" "--" "%1"',
    'cmd.exe /c start %1',
  ]) {
    test('refuses changed protocol template $unsafe', () async {
      var launched = false;
      final launcher = SodaTrackLauncher(
          supported: true,
          exists: (_) => true,
          inspect: () async => (command: unsafe, runningPaths: [executable]),
          launch: (_, __) async => launched = true);
      await expectLater(launcher.play('123', beforeDispatch: () {}),
          throwsA(code('soda_handler_changed')));
      expect(launched, isFalse);
    });
  }

  test('requires handler executable to match an already running Soda process',
      () async {
    final launcher = SodaTrackLauncher(
        supported: true,
        exists: (_) => true,
        inspect: () async => (command: command, runningPaths: <String>[]));
    await expectLater(launcher.play('123', beforeDispatch: () {}),
        throwsA(code('soda_not_running')));
  });

  test('takeover refusal after registry lookup cannot launch', () async {
    var launched = false;
    final launcher = SodaTrackLauncher(
        supported: true,
        exists: (_) => true,
        inspect: () async => (command: command, runningPaths: [executable]),
        launch: (_, __) async => launched = true);
    await expectLater(
        launcher.play('123', beforeDispatch: () {
          throw const RemoteFailure('control_lost');
        }),
        throwsA(code('control_lost')));
    expect(launched, isFalse);
  });

  group('remembered 汽水 check', () {
    var now = DateTime(2026, 10, 22, 19);
    late int inspections;
    late List<String> running;
    late List<String> launched;
    late SodaTrackLauncher launcher;
    setUp(() {
      now = DateTime(2026, 10, 22, 19);
      inspections = 0;
      running = [executable];
      launched = [];
      launcher = SodaTrackLauncher(
          supported: true,
          exists: (_) => true,
          clock: () => now,
          inspect: () async {
            inspections++;
            return (command: command, runningPaths: List.of(running));
          },
          launch: (_, args) async => launched.add(args.last));
    });

    test('a tap after the sheet opened does not read again', () async {
      launcher.prefetch();
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 10));
      await launcher.play('123', beforeDispatch: () {});
      expect(inspections, 1);
      expect(launched, hasLength(1));
    });

    test('prefetch while a reading is running shares it', () async {
      launcher.prefetch();
      launcher.prefetch();
      await launcher.play('123', beforeDispatch: () {});
      expect(inspections, 1);
    });

    test('an old reading is read again', () async {
      launcher.prefetch();
      await Future<void>.delayed(Duration.zero);
      now = now.add(SodaTrackLauncher.identityFreshFor);
      await launcher.play('123', beforeDispatch: () {});
      expect(inspections, 2);
    });

    test('a remembered reading that no longer passes is read again once',
        () async {
      running = [];
      launcher.prefetch();
      await Future<void>.delayed(Duration.zero);
      running = [executable]; // 汽水 was started after the sheet opened
      await launcher.play('123', beforeDispatch: () {});
      expect(inspections, 2);
      expect(launched, hasLength(1));
    });

    test('a fresh reading that fails is reported, not retried', () async {
      running = [];
      await expectLater(launcher.play('123', beforeDispatch: () {}),
          throwsA(code('soda_not_running')));
      expect(inspections, 1);
      expect(launched, isEmpty);
    });

    test('a failed prefetch is ignored and the tap reads again', () async {
      var fail = true;
      final flaky = SodaTrackLauncher(
          supported: true,
          exists: (_) => true,
          clock: () => now,
          inspect: () async {
            inspections++;
            if (fail) throw const ProcessException('synthetic', []);
            return (command: command, runningPaths: [executable]);
          },
          launch: (_, args) async => launched.add(args.last));
      flaky.prefetch();
      await Future<void>.delayed(Duration.zero);
      fail = false;
      await flaky.play('123', beforeDispatch: () {});
      expect(inspections, 2);
      expect(launched, hasLength(1));
    });
  });

  test('dispatch uncertainty never retries or reports a pre-action error',
      () async {
    var attempts = 0;
    final launcher = SodaTrackLauncher(
        supported: true,
        exists: (_) => true,
        inspect: () async => (command: command, runningPaths: [executable]),
        launch: (_, __) async {
          attempts++;
          throw const ProcessException('synthetic', []);
        });
    await expectLater(launcher.play('123', beforeDispatch: () {}),
        throwsA(code('soda_dispatch_uncertain')));
    expect(attempts, 1);
  });
}
