import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';

import 'listen_room_bridge_test.dart' show FakeSession, snapshot;

class QueueSession extends FakeSession {
  Future<bool>? playGate, takeGate;

  @override
  Future<bool> command(String type,
      [Map<String, dynamic> payload = const {}]) async {
    final ok = await super.command(type, payload);
    return await playGate ?? ok;
  }

  @override
  Future<bool> takeControl() async {
    if (takeGate == null) return super.takeControl();
    calls.add('take');
    return control = await takeGate!;
  }
}

Map<String, dynamic> cached(
        {String revision = 'private_rev',
        String list = 'private_list',
        String snap = 'private_snapshot',
        String title = 'Evening',
        List<Map<String, dynamic>>? rows,
        bool historical = false}) =>
    {
      'available': true,
      'revision': revision,
      'lists': [],
      'list': {
        'id': list,
        'title': title,
        'snapshots': [
          {'id': snap, 'historical': historical},
        ]
      },
      'page': {
        'snapshot': snap,
        'offset': 0,
        'historical': historical,
        'rows': rows ??
            [
              {
                'id': 'private_a',
                'title': 'A',
                'artist': 'Artist A',
                'playable': true
              },
              {
                'id': 'private_b',
                'title': 'B',
                'artist': 'Artist B',
                'playable': true
              },
            ]
      },
    };

Map<String, dynamic> online(
        {String revision = 'private_online_rev',
        String query = 'night',
        bool ready = true}) =>
    {
      'kind': 'search',
      'query': query,
      'revision': revision,
      'playbackReady': ready,
      'modes': [],
      'rows': [
        {
          'id': 'private_online_a',
          'title': 'Online A',
          'artist': 'Artist A',
          'playable': true,
          'durationMs': 100000
        },
        {
          'id': 'private_online_b',
          'title': 'Online B',
          'artist': 'Artist B',
          'playable': true,
          'durationMs': 100000
        },
      ],
    };

class Harness {
  Harness({Future<void> Function(String script)? onRun}) {
    s.snapshot = snapshot(liveRunning: false)..['hostSessionId'] = 'host_one';
    s.snapshot!['capabilities'].addAll({
      'sodaLibrary': true,
      'sodaOnline': true,
      'sodaOnlinePlay': true,
      'sodaSearch': true,
    });
    b = ListenRoomBridge(
        session: s,
        run: (script) async {
          scripts.add(script);
          await onRun?.call(script);
        });
    b.attach();
    addTearDown(() {
      b.dispose();
      s.dispose();
    });
  }
  final s = QueueSession();
  final scripts = <String>[];
  late final ListenRoomBridge b;
  Future<void> intent(Map<String, dynamic> value) =>
      b.handle(jsonEncode(value));
  Future<void> browse([Map<String, dynamic>? value]) async {
    final response = value ?? cached();
    s.browseGate = Future.value(response);
    await intent({
      't': 'musicBrowse',
      'request': 1,
      'list': response['list']?['id'] ?? 'private_list'
    });
  }

  Future<void> search([Map<String, dynamic>? value]) async {
    final response = value ?? online();
    s.onlineRead = (_, __) async => response;
    await intent({
      't': 'musicOnline',
      'request': 1,
      'kind': 'search',
      'query': response['query']
    });
  }

  Future<void> play(
          {bool online = false,
          String track = 'private_a',
          String revision = 'private_rev',
          String list = 'private_list',
          String snap = 'private_snapshot'}) =>
      intent({
        't': online ? 'musicOnlinePlay' : 'musicPlay',
        'track': track,
        'revision': revision,
        if (!online) 'list': list,
        if (!online) 'snapshot': snap,
      });
  Map<String, dynamic>? get queue =>
      b.state()['queue'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get commands => [
        for (final call in s.calls.where(
            (c) => c.startsWith('library.play ') || c.startsWith('soda.play ')))
          {
            'command': call.split(' ').first,
            'payload': jsonDecode(call.substring(call.indexOf(' ') + 1))
          },
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only successful cached sheet play establishes metadata queue',
      () async {
    final h = Harness();
    expect(h.queue, isNull);
    await h.browse();
    expect(h.queue, isNull);
    h.s.commandWorks = false;
    await h.play();
    expect(h.queue, isNull);
    h.s.commandWorks = true;
    await h.play();
    expect(h.queue, {
      'title': 'Evening',
      'playing': -1,
      'songs': [
        {'title': 'A', 'artist': 'Artist A'},
        {'title': 'B', 'artist': 'Artist B'},
      ]
    });
    expect(h.commands.last['command'], 'library.play');
  });

  test(
      'playing index follows snapshot title AND artist, never the requested row',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    h.s.snapshot!['track'] = {'title': 'B', 'artist': 'Artist B'};
    expect(h.queue!['playing'], 1);
    await h.intent({'t': 'queuePlay', 'i': 0});
    expect(h.queue!['playing'], 1, reason: 'wait for actual host snapshot');
    h.s.snapshot!['track'] = {'title': 'A', 'artist': 'Artist A'};
    expect(h.queue!['playing'], 0);
    h.s.snapshot!['track'] = {'title': 'A', 'artist': 'Another artist'};
    expect(h.queue!['playing'], -1);
  });

  test(
      'cached queuePlay maps index to original list, snapshot, track and revision',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands.single, {
      'command': 'library.play',
      'payload': {
        'list': 'private_list',
        'snapshot': 'private_snapshot',
        'track': 'private_b',
        'revision': 'private_rev',
      }
    });
  });

  test(
      'latest displayed page per list/snapshot is retained without fetching unseen songs',
      () async {
    final h = Harness();
    await h.browse();
    await h
        .browse(cached(list: 'other_list', snap: 'other_snap', title: 'Other'));
    await h.play();
    expect(h.queue!['title'], 'Evening');
    final page = cached(rows: [
      {
        'id': 'private_c',
        'title': 'Page two',
        'artist': 'Band',
        'playable': true
      },
    ]);
    page['page']['offset'] = 100;
    await h.browse(page);
    await h.play(track: 'private_c');
    expect(h.queue!['songs'], [
      {'title': 'Page two', 'artist': 'Band'}
    ]);
  });

  test(
      'online sheet play builds search queue and queuePlay reuses soda.play identities',
      () async {
    final h = Harness();
    await h.search();
    expect(h.queue, isNull);
    await h.play(
        online: true,
        track: 'private_online_a',
        revision: 'private_online_rev');
    expect(h.queue!['title'], 'Search: night');
    expect(h.queue!['songs'], hasLength(2));
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands.single, {
      'command': 'soda.play',
      'payload': {
        'track': 'private_online_b',
        'revision': 'private_online_rev',
      }
    });
  });

  test(
      'private ids never enter queue/page state and returned state cannot mutate routing',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    expect(jsonEncode(h.b.state()), isNot(contains('private_')));
    await h.intent({'t': 'ready'});
    expect(h.scripts.where((v) => v.startsWith('YinweiListen.apply')),
        everyElement(isNot(contains('private_'))));
    final page = h.queue!;
    page['songs'][0]['title'] = 'Injected';
    expect(h.queue!['songs'][0]['title'], 'A');
    await h.search();
    await h.play(
        online: true,
        track: 'private_online_a',
        revision: 'private_online_rev');
    expect(jsonEncode(h.b.state()), isNot(contains('private_')));
  });

  test(
      'missing, non-integer, negative and out-of-range queue indices are ignored',
      () async {
    final h = Harness();
    await h.intent({'t': 'queuePlay', 'i': 0});
    expect(h.s.calls, isEmpty);
    await h.browse();
    await h.play();
    h.s.calls.clear();
    for (final i in [null, '1', 1.0, 1.5, true, -1, 2, 999999]) {
      await h.intent({'t': 'queuePlay', 'i': i});
    }
    expect(h.s.calls, isEmpty);
  });

  test(
      'changed library revision delegates active selection validation to the laptop',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    await h.browse({'revision': 'new_revision', 'lists': []});
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands, hasLength(1));
  });

  test(
      'replaced online search delegates retained selection validation to the laptop',
      () async {
    final h = Harness();
    await h.search();
    await h.play(
        online: true,
        track: 'private_online_a',
        revision: 'private_online_rev');
    await h.search(online(query: 'other', revision: 'other_rev'));
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands, hasLength(1));
    await h.search(online(revision: 'new_revision'));
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands, hasLength(1));
  });

  test(
      'queue selection respects capabilities, pending, sign-in and sheet play lock',
      () async {
    for (final useOnline in [false, true]) {
      final h = Harness();
      if (useOnline) {
        await h.search();
        await h.play(
            online: true,
            track: 'private_online_a',
            revision: 'private_online_rev');
      } else {
        await h.browse();
        await h.play();
      }
      h.s.calls.clear();
      final cap = useOnline ? 'sodaOnlinePlay' : 'sodaLibrary';
      h.s.snapshot!['capabilities'][cap] = false;
      await h.intent({'t': 'queuePlay', 'i': 1});
      expect(h.s.calls, isEmpty);
      h.s.snapshot!['capabilities'][cap] = true;
      h.s.pending = true;
      await h.intent({'t': 'queuePlay', 'i': 1});
      expect(h.s.calls, isEmpty);
      h.s.pending = false;
      final gate = Completer<bool>();
      h.s.playGate = gate.future;
      final playing = h.intent({'t': 'queuePlay', 'i': 1});
      await Future<void>.delayed(Duration.zero);
      await h.intent({'t': 'queuePlay', 'i': 0});
      await h.play(
          online: useOnline,
          track: useOnline ? 'private_online_a' : 'private_a',
          revision: useOnline ? 'private_online_rev' : 'private_rev');
      expect(h.commands, hasLength(1));
      gate.complete(true);
      await playing;
      h.s.signed = false;
      h.s.calls.clear();
      await h.intent({'t': 'queuePlay', 'i': 1});
      expect(h.s.calls, isEmpty);
      expect(h.queue, isNull);
    }
  });

  test('historical and unplayable browse rows cannot be selected from a queue',
      () async {
    final h = Harness();
    await h.browse(cached(rows: [
      {'id': 'private_a', 'title': 'A', 'artist': 'Artist A', 'playable': true},
      {
        'id': 'private_b',
        'title': 'B',
        'artist': 'Artist B',
        'playable': false
      },
    ]));
    await h.play();
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.s.calls, isEmpty);
    await h.browse(cached(revision: 'old_page', historical: true));
    await h.play(revision: 'old_page');
    expect(h.queue, isNull);
  });

  test('sign-out and host changes clear queue and retained browse ids',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    await h.intent({'t': 'signOut'});
    expect(h.queue, isNull);
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 0});
    expect(h.s.calls, isEmpty);
    await h.browse();
    await h.play();
    h.s.set((s) => s.snapshot!['hostSessionId'] = 'host_two');
    expect(h.queue, isNull);
    h.s.set((s) => s.snapshot!['hostSessionId'] = 'host_one');
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 0});
    expect(h.s.calls, isEmpty);
    await h.play();
    expect(h.queue, isNull, reason: 'old browse cache was cleared too');
  });

  test('host change while acquiring control prevents queue command dispatch',
      () async {
    final h = Harness();
    await h.browse();
    await h.play();
    h.s.control = false;
    h.s.calls.clear();
    final gate = Completer<bool>();
    h.s.takeGate = gate.future;
    final playing = h.intent({'t': 'queuePlay', 'i': 1});
    await Future<void>.delayed(Duration.zero);
    h.s.set((s) => s.snapshot!['hostSessionId'] = 'host_two');
    gate.complete(true);
    await playing;
    expect(h.commands, isEmpty);
    expect(h.queue, isNull);
  });

  test(
      'in-flight successful play cannot restore queue after sign-out or host change',
      () async {
    for (final signOut in [false, true]) {
      final h = Harness();
      await h.browse();
      final gate = Completer<bool>();
      h.s.playGate = gate.future;
      final playing = h.play();
      await Future<void>.delayed(Duration.zero);
      if (signOut) {
        await h.intent({'t': 'signOut'});
      } else {
        h.s.set((s) => s.snapshot!['hostSessionId'] = 'host_two');
      }
      gate.complete(true);
      await playing;
      expect(h.queue, isNull);
    }
  });

  test('late browse after host change is neither shown nor retained as a queue',
      () async {
    final h = Harness();
    final gate = Completer<Map<String, dynamic>>();
    h.s.browseGate = gate.future;
    final reading =
        h.intent({'t': 'musicBrowse', 'request': 1, 'list': 'private_list'});
    await Future<void>.delayed(Duration.zero);
    h.s.set((s) => s.snapshot!['hostSessionId'] = 'host_two');
    gate.complete(cached());
    await reading;
    await h.play();
    expect(h.queue, isNull);
    expect(h.scripts, isEmpty);
  });
  test('failed online play keeps the last successful queue', () async {
    final h = Harness();
    await h.browse();
    await h.play();
    await h.search();
    h.s.commandWorks = false;
    await h.play(
        online: true,
        track: 'private_online_a',
        revision: 'private_online_rev');
    expect(h.queue!['title'], 'Evening');
  });

  test('cached search queue retains each song own list and snapshot ids',
      () async {
    final h = Harness();
    final response = {
      'revision': 'private_rev',
      'lists': [],
      'search': {
        'query': 'night',
        'rows': [
          {
            'id': 'private_a',
            'list': 'private_list',
            'snapshot': 'private_snapshot',
            'title': 'A',
            'artist': 'Artist A',
            'playable': true
          },
          {
            'id': 'private_b',
            'list': 'other_list',
            'snapshot': 'other_snapshot',
            'title': 'B',
            'artist': 'Artist B',
            'playable': true
          },
        ]
      },
    };
    await h.browse(response);
    await h.play();
    h.s.calls.clear();
    await h.intent({'t': 'queuePlay', 'i': 1});
    expect(h.commands.single['payload'], {
      'list': 'other_list',
      'snapshot': 'other_snapshot',
      'track': 'private_b',
      'revision': 'private_rev'
    });
  });
}
