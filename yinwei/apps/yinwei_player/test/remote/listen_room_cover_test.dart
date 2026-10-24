// Real song covers through the bridge (docs/IMPLEMENTATION_LISTEN_ROOM_COVERS.md, C2).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_cover_cache.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';

import 'listen_room_bridge_test.dart' show FakeSession, snapshot;
import 'listen_room_queue_test.dart' show cached;

class CoverSession extends FakeSession {
  final coverCalls = <Map<String, dynamic>>[];
  Map<String, dynamic> reply = {
    'mime': 'image/jpeg',
    'data': base64Encode([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3])
  };

  @override
  Future<Map<String, dynamic>> sodaCover(Map<String, dynamic> payload) async {
    coverCalls.add(payload);
    return reply;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoverSession s;
  late ListenRoomBridge b;
  late List<String> scripts;
  late Directory dir;

  Future<void> setUpBridge({bool covers = true}) async {
    s = CoverSession();
    s.snapshot = snapshot(liveRunning: false)..['hostSessionId'] = 'host_one';
    s.snapshot!['capabilities'].addAll({
      'sodaLibrary': true,
      'sodaSearch': true,
      if (covers) 'sodaCovers': true,
    });
    dir = await Directory.systemTemp.createTemp('yw-ipad-covers-');
    scripts = [];
    b = ListenRoomBridge(
        session: s,
        run: (script) async => scripts.add(script),
        coverCache: ListenCoverCache(directory: dir));
    b.attach();
    await b.handle('{"t":"ready"}');
    s.browseGate = Future.value(cached());
    await b.handle(jsonEncode(
        {'t': 'musicBrowse', 'request': 1, 'list': 'private_list'}));
    await b.handle(jsonEncode({
      't': 'musicPlay',
      'track': 'private_a',
      'revision': 'private_rev',
      'list': 'private_list',
      'snapshot': 'private_snapshot'
    }));
    scripts.clear();
  }

  tearDown(() async {
    b.dispose();
    s.dispose();
    await dir.delete(recursive: true);
  });

  List<String> keys() => [
        for (final song in (b.state()['queue'] as Map)['songs'] as List)
          (song as Map)['cover'] as String
      ];

  test('without the laptop capability: no cover keys, nothing requested',
      () async {
    await setUpBridge(covers: false);
    final state = b.state();
    expect(state['covers'], isFalse);
    expect(((state['queue'] as Map)['songs'] as List).first,
        isNot(contains('cover')));
  });

  test('each queue song gets an opaque key; no IDs reach the page', () async {
    await setUpBridge();
    final k = keys();
    expect(k, hasLength(2));
    expect(k.every((x) => RegExp(r'^[0-9a-f]{16}$').hasMatch(x)), isTrue);
    expect(k.toSet(), hasLength(2));
    final page = jsonEncode(b.state());
    for (final secret in ['private_a', 'private_b', 'private_list', 'private_snapshot', 'private_rev']) {
      expect(page.contains(secret), isFalse, reason: secret);
    }
    expect(b.state()['covers'], isTrue);
  });

  test('a request fetches once from the laptop, then from the iPad cache',
      () async {
    await setUpBridge();
    final key = keys().first;
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': key}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(s.coverCalls, hasLength(1));
    expect(s.coverCalls.single, {
      'source': 'library',
      'list': 'private_list',
      'snapshot': 'private_snapshot',
      'track': 'private_a',
      'revision': 'private_rev'
    });
    expect(
        scripts.where((x) => x.startsWith('YinweiListen.cover("$key", "data:image/jpeg;base64,')),
        hasLength(1));
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': key}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(s.coverCalls, hasLength(1), reason: 'served from the iPad cache');
    expect(dir.listSync().map((f) => f.path).join().contains('private_a'),
        isFalse, reason: 'no IDs in cache file names');
  });

  test('unknown keys and bad replies give no cover', () async {
    await setUpBridge();
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': '0000000000000000'}));
    expect(scripts.last, 'YinweiListen.cover("0000000000000000", null)');
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': 'not-a-key'}));
    s.reply = {'mime': 'text/html', 'data': 'PGh0bWw+'};
    final key = keys()[1];
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': key}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(scripts.last, 'YinweiListen.cover("$key", null)');
  });

  test('in the background nothing is sent to the page', () async {
    await setUpBridge();
    b.background = true;
    await b.handle(jsonEncode({'t': 'coverRequest', 'key': keys().first}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(scripts.where((x) => x.startsWith('YinweiListen.cover')), isEmpty);
  });
}
