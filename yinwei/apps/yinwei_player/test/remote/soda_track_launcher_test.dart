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
