// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'listen_room_queue_test.dart' show Harness, cached;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('500-song queue is sent once while telemetry changes', () async {
    final h = Harness();
    await h.intent({'t': 'ready'});
    await h.browse(cached(
        rows: List.generate(
            500,
            (i) => {
                  'id': i == 0 ? 'private_a' : 'private_$i',
                  'title': 'Song $i',
                  'artist': 'Artist $i',
                  'playable': true,
                })));
    await h.play();
    final clock = Stopwatch()..start();
    await h.b.push(force: true);
    final first = h.scripts.last;
    final firstUs = clock.elapsedMicroseconds;
    h.scripts.clear();
    final durations = <int>[];
    for (var i = 0; i < 100; i++) {
      h.s.snapshot!['transport'] = {'playing': i.isEven};
      clock.reset();
      await h.b.push();
      durations.add(clock.elapsedMicroseconds);
    }
    durations.sort();
    final repeats = h.scripts.where((s) => s.contains('Song 499')).length;
    print('TAP_BENCH ${jsonEncode({
          'initialBytes': utf8.encode(first).length,
          'deltaBytes': utf8.encode(h.scripts.last).length,
          'initialUs': firstUs,
          'pushP50Us': durations[50],
          'pushP95Us': durations[95],
          'repeatedQueueMessages': repeats,
          'messages': h.scripts.length
        })}');
    expect(repeats, 0);
    expect(h.scripts, isNotEmpty);
  });

  test('browse revision refresh leaves active and retained sheet taps playable',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    await h.browse({'revision': 'new_revision', 'lists': []});
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands, hasLength(1));
    await h.play();
    expect(h.queue, isNotNull);
  });

  test('Live queue index follows Live metadata instead of the file track',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    h.s.snapshot!['liveRunning'] = true;
    h.s.snapshot!['live'] = {'title': 'B', 'playing': true};
    expect(h.queue!['playing'], 1);
  });

  test('ten pending queue taps each produce an explanation', () async {
    final h = Harness();
    await h.intent({'t': 'ready'});
    await h.browse();
    await h.play();
    h.scripts.clear();
    h.s.pending = true;
    for (var i = 0; i < 10; i++) {
      await h.intent({'t': 'queuePlay', 'i': i % 2});
    }
    expect(h.scripts.where((s) => s.startsWith('YinweiListen.toast')),
        hasLength(10));
  });
  test('WebView sends coalesce while a previous run is unfinished', () async {
    Completer<void>? gate;
    var active = 0, maximum = 0;
    final h = Harness(onRun: (_) async {
      active++;
      if (active > maximum) maximum = active;
      await gate?.future;
      active--;
    });
    await h.intent({'t': 'ready'});
    gate = Completer<void>();
    final first = h.b.push(force: true);
    await Future<void>.delayed(Duration.zero);
    h.s.snapshot!['transport'] = {'playing': true};
    final rest = List.generate(10, (_) => h.b.push());
    final release = gate;
    gate = null;
    release.complete();
    await Future.wait([first, ...rest]);
    expect(maximum, 1);
    expect(h.scripts.last, contains('"playing":true'));
  });

  test('reload resends queue metadata and a host change explicitly clears it',
      () async {
    final h = Harness();
    await h.intent({'t': 'ready'});
    await h.browse();
    await h.play();
    await h.b.push();
    h.b.pageReloaded();
    await h.intent({'t': 'ready'});
    expect(h.scripts.last, contains('"songs"'));
    h.s.snapshot!['hostSessionId'] = 'new_host';
    await h.b.push();
    expect(h.scripts.last, contains('"queue":null'));
  });

  test(
      'ambiguous Live titles stay unknown instead of highlighting another artist',
      () async {
    final h = Harness();
    await h.browse(cached(rows: [
      {'id': 'private_a', 'title': 'Same', 'artist': 'First', 'playable': true},
      {
        'id': 'private_b',
        'title': 'Same',
        'artist': 'Second',
        'playable': true
      },
    ]));
    await h.play();
    h.s.snapshot!['liveRunning'] = true;
    h.s.snapshot!['live'] = {'title': 'Same', 'playing': true};
    expect(h.queue!['playing'], -1);
  });
}
