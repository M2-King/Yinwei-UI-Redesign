import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/remote_media_keys.dart';

/// A PowerShell stand-in: answers each `Send-YinweiKey <action>` line.
class FakeHelper implements Process {
  FakeHelper(this.answer, {this.ready = true}) {
    _in.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      lines.add(line);
      if (line.startsWith('. ')) {
        if (ready) _out.add(utf8.encode('ready\r\n'));
      } else if (line.startsWith('Send-YinweiKey ')) {
        final reply = answer(line.substring('Send-YinweiKey '.length));
        if (reply != null) _out.add(utf8.encode('$reply\r\n'));
      }
    });
  }

  final String? Function(String action) answer;
  final bool ready;
  final lines = <String>[];
  bool killed = false;
  final _in = StreamController<List<int>>();
  final _out = StreamController<List<int>>();

  @override
  late final IOSink stdin = IOSink(_in.sink);
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => killed = true;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  int get pid => 1;
}

void main() {
  late List<FakeHelper> started;
  late List<String> fallbacks;
  late String? Function(String) answer;

  RemoteMediaKeys keys({bool ready = true}) => RemoteMediaKeys(
        fallback: (action) async => fallbacks.add(action),
        start: () async {
          final helper = FakeHelper(answer, ready: ready);
          started.add(helper);
          return helper;
        },
        timeout: const Duration(milliseconds: 200),
      );

  setUp(() {
    started = [];
    fallbacks = [];
    answer = (_) => 'ok';
  });

  test('one helper serves every tap, loaded once, in order', () async {
    final k = keys();
    await Future.wait([k.send('play'), k.send('pause'), k.send('next')]);
    expect(started.length, 1);
    expect(started.single.lines.first, startsWith(". '"));
    expect(started.single.lines.skip(1), [
      'Send-YinweiKey play',
      'Send-YinweiKey pause',
      'Send-YinweiKey next',
    ]);
    expect(fallbacks, isEmpty);
  });

  test('warm-up starts the helper before the first tap', () async {
    final k = keys();
    await k.warmUp();
    expect(started.length, 1);
    await k.send('play');
    expect(started.length, 1);
    expect(k.lastTiming['warm'], isTrue);
    expect(k.lastTiming['fallback'], isFalse);
    expect(k.lastTiming['ackMs'], isNonNegative);
  });

  test('the app refusing, or no session, throws like the one-off command',
      () async {
    final k = keys();
    answer = (_) => 'refused';
    await expectLater(k.send('next'), throwsA(isA<ProcessException>()));
    answer = (_) => 'nosession';
    await expectLater(k.send('play'), throwsA(isA<ProcessException>()));
    expect(fallbacks, isEmpty);
    expect(started.length, 1, reason: 'a refusal is not a broken helper');
  });

  test('no answer in time: the one-off command, then a fresh helper', () async {
    final k = keys();
    answer = (_) => null;
    await k.send('pause');
    expect(fallbacks, ['pause']);
    expect(started.single.killed, isTrue);
    answer = (_) => 'ok';
    await k.send('play');
    expect(started.length, 2);
    expect(fallbacks, ['pause']);
  });

  test('a helper that never gets ready falls back', () async {
    final k = keys(ready: false);
    await k.send('play');
    expect(fallbacks, ['play']);
  });

  test('only the four keys are accepted', () {
    expect(() => keys().send('Remove-Item C:\\'), throwsArgumentError);
  });
}
