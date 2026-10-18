import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';

/// Scripted stand-in for the `serve` helper: replies to each JSON request.
class _FakeHelper {
  _FakeHelper(this.reply);

  final List<String>? Function(List<String> args) reply;
  final _lines = StreamController<String>();
  final requests = <List<String>>[];

  RouteHelperConnection get connection => RouteHelperConnection(
        lines: _lines.stream,
        send: (line) {
          final args = (jsonDecode(line) as List).cast<String>();
          requests.add(args);
          final lines = reply(args);
          if (lines == null) return; // hang: no reply
          scheduleMicrotask(() => lines.forEach(_lines.add));
        },
        close: end,
      );

  Future<void> end() async {
    if (!_lines.isClosed) await _lines.close();
  }
}

void main() {
  test('serializes commands and returns lines and exit code', () async {
    var connects = 0;
    late _FakeHelper helper;
    final client = RouteHelperClient(() async {
      ++connects;
      helper = _FakeHelper((args) => switch (args.first) {
            'list' => ['sink|Steam|id-1', '__YW_END__ 0'],
            'mute-state' => ['MUTED_WAS -1', '__YW_END__ 4'],
            _ => ['__YW_END__ 0'],
          });
      return helper.connection;
    });
    final results = await Future.wait([
      client.run(['list']),
      client.run(['mute-state', r'\\?\SWD#MMDEVAPI#{0.0.0.0}']),
    ]);
    expect(results[0].code, 0);
    expect(results[0].lines, ['sink|Steam|id-1']);
    expect(results[1].code, 4);
    expect(results[1].lines, ['MUTED_WAS -1']);
    expect(helper.requests[1], ['mute-state', r'\\?\SWD#MMDEVAPI#{0.0.0.0}']);
    expect(connects, 1);
  });

  test('a helper that ends fails the command and reconnects next time',
      () async {
    final helpers = <_FakeHelper>[];
    final client = RouteHelperClient(() async {
      final helper = _FakeHelper(
          (args) => args.first == 'crash' ? null : ['PONG', '__YW_END__ 0']);
      helpers.add(helper);
      return helper.connection;
    });
    final crashed = client.run(['crash']);
    await Future<void>.delayed(Duration.zero);
    await helpers.single.end();
    await expectLater(crashed, throwsStateError);
    final next = await client.run(['ping']);
    expect(next.lines, ['PONG']);
    expect(helpers, hasLength(2));
    expect(client.abandoned, isFalse);
  });

  test('two timeouts abandon the helper', () async {
    final client = RouteHelperClient(
      () async => _FakeHelper((_) => null).connection,
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(client.run(['list']), throwsA(isA<TimeoutException>()));
    expect(client.abandoned, isFalse);
    await expectLater(client.run(['list']), throwsA(isA<TimeoutException>()));
    expect(client.abandoned, isTrue);
    await expectLater(client.run(['list']), throwsStateError);
  });

  // Real helper on Windows: set YINWEI_ROUTE_SCRIPT to an extracted copy of
  // the routing script. Read-only commands only.
  final script = Platform.environment['YINWEI_ROUTE_SCRIPT'];
  test('real PowerShell helper answers read-only commands quickly', () async {
    final client = RouteHelperClient(() => connectRouteHelper(script!));
    addTearDown(client.close);
    expect((await client.run(['ping'])).lines, ['PONG']);
    final timings = <int>[];
    late ({int code, List<String> lines}) list;
    for (var i = 0; i < 3; ++i) {
      final watch = Stopwatch()..start();
      list = await client.run(['list']);
      timings.add(watch.elapsedMilliseconds);
    }
    expect(list.code, 0);
    expect(list.lines.where((l) => l.startsWith('speakers|')), isNotEmpty);
    final bad = await client.run(['mute-state', 'not-a-device']);
    expect(bad.code, 4);
    expect(bad.lines, ['MUTED_WAS -1']);
    // ignore: avoid_print
    print('real helper: list ms $timings; rows ${list.lines}');
    expect(timings.last, lessThan(1000));
  }, skip: script == null || !Platform.isWindows);
}
