import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/soda_cache_reader.dart';
import 'package:yinwei_player/remote/soda_library.dart';

void main() {
  late Directory store;
  late FakeReader reader;
  late SodaLibrary library;
  late List<Map<String, Object?>> logs;
  setUp(() async {
    store = await Directory.systemTemp.createTemp('soda-library-');
    reader = FakeReader(frame(List.generate(31, (i) => '${1000 + i}')));
    logs = [];
    library =
        SodaLibrary(reader: reader, storageDirectory: store, log: logs.add);
  });
  tearDown(() async {
    await store.delete(recursive: true);
  });

  test('list, snapshot and row tokens never expose provider/account identities',
      () async {
    final top = await library.browse({});
    final id = top['lists'][0]['id'];
    final view = await library.browse({'list': id});
    final page = view['page'];
    for (final token in [
      id,
      view['revision'],
      page['snapshot'],
      page['rows'][0]['id']
    ]) {
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{1,160}$')));
      expect(token, isNot('456'));
    }
    final wire = jsonEncode(view);
    expect(wire, isNot(contains('accountId')));
    expect(wire, isNot(contains('providerId')));
    expect(
        await library.resolveTrack({
          'list': id,
          'snapshot': page['snapshot'],
          'track': page['rows'][0]['id'],
          'revision': view['revision']
        }),
        '1000');
  });
  for (final replacement in [false, true]) {
    test(
        '31 to8 retains old view without union (${replacement ? 'partial overlap' : 'subset'})',
        () async {
      var view = await library.browse({});
      final list = view['lists'][0]['id'];
      view = await library.browse({'list': list});
      final oldPage = view['page'];
      final next =
          List.generate(8, (i) => '${(replacement ? 1027 : 1000) + i}');
      reader.state = frame(next, time: 2000, revision: 'second');
      await library.refresh();
      view = await library.browse({'list': list});
      expect(view['list']['cached'], 8);
      expect(view['list']['total'], 33);
      expect(view['list']['partial'], true);
      expect(view['list']['historyCount'], 1);
      final history =
          await library.browse({'list': list, 'snapshot': oldPage['snapshot']});
      expect(history['page']['rows'], hasLength(31));
      expect(
          history['page']['rows'].every((dynamic r) => r['playable'] == false),
          true);
      expect(
          history['list']['snapshots'][1]['updatedAt'],
          DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true)
              .toIso8601String());
      await expectLater(
          library.resolveTrack({
            'list': list,
            'snapshot': oldPage['snapshot'],
            'track': oldPage['rows'][0]['id']
          }),
          throwsA(isA<SodaLibraryFailure>()
              .having((e) => e.code, 'code', 'soda_stale_selection')));
      await library.refresh();
      expect(logs, [
        {
          'event': 'music_cache_shrank',
          'previousCount': 31,
          'currentCount': 8,
          'reportedTotal': 33
        }
      ]);
      expect(logs.toString(), isNot(contains('Synthetic')));
      expect(
          await store.list(recursive: true).where((f) => f is File).length, 2);
    });
  }
  test('equal count membership replacements are separate dated snapshots',
      () async {
    await library.refresh();
    reader.state = frame(List.generate(31, (i) => '${2000 + i}'),
        time: 3000, revision: 'replacement');
    await library.refresh();
    final top = await library.browse({});
    expect(top['lists'][0]['historyCount'], 1);
    expect(logs, isEmpty);
  });
  test('removed catalog list retains same-session history but cannot play',
      () async {
    final top = await library.browse({});
    final list = top['lists'][0]['id'];
    final view = await library.browse({'list': list});
    reader.state =
        const SodaCacheState(accountId: '123', revision: 'removed', catalog: {
      'time': 2000,
      'data': {'playlists': []}
    }, details: {});
    await library.refresh();
    final retained = await library.browse({'list': list});
    expect(retained['list']['historical'], true);
    expect(retained['page']['historical'], true);
    expect(retained['page']['rows'], hasLength(31));
    expect(retained['page']['rows'][0]['playable'], false);
    await expectLater(
        library.resolveTrack({
          'list': list,
          'snapshot': view['page']['snapshot'],
          'track': view['page']['rows'][0]['id'],
          'revision': view['revision']
        }),
        throwsA(isA<SodaLibraryFailure>()));
    expect(await store.list(recursive: true).where((f) => f is File).length, 1);
  });
  test('private history orders rapid snapshots even with a fixed clock',
      () async {
    library = SodaLibrary(
        reader: reader,
        storageDirectory: store,
        clock: () => DateTime.utc(2026));
    await library.refresh();
    reader.state = frame(['1000'], revision: 'second', time: 2000);
    await library.refresh();
    final restarted = SodaLibrary(reader: reader, storageDirectory: store);
    final top = await restarted.browse({});
    expect(top['lists'][0]['cached'], 1);
    expect(top['lists'][0]['historyCount'], 1);
    expect(await store.list(recursive: true).where((f) => f is File).length, 2);
  });
  test('account change invalidates all opaque handles and segregates history',
      () async {
    final top = await library.browse({});
    final old = top['lists'][0]['id'];
    reader.state = frame(['9000'], account: '999', revision: 'otheraccount');
    await library.refresh();
    final current = await library.browse({});
    expect(current['lists'][0]['id'], isNot(old));
    expect(current['lists'][0]['historyCount'], 0);
    await expectLater(
        library.browse({'list': old}), throwsA(isA<SodaLibraryFailure>()));
    expect(await store.list().where((f) => f is Directory).length, 2);
  });
  test('debounced browse rechecks account before serving any cached row',
      () async {
    final old = await library.browse({});
    reader.state = frame(['9000'], account: '999', revision: 'newaccount');
    final current = await library.browse({});
    expect(current['lists'][0]['id'], isNot(old['lists'][0]['id']));
    expect(current['lists'][0]['cached'], 1);
    expect(current['lists'][0]['historyCount'], 0);
  });
  test(
      'logout/read failure cannot serve the previous account or play old handles',
      () async {
    final top = await library.browse({});
    reader.failure = const SodaCacheFailure('soda_no_account');
    await expectLater(library.refresh(), throwsA(isA<SodaLibraryFailure>()));
    await expectLater(library.browse({'list': top['lists'][0]['id']}),
        throwsA(isA<SodaLibraryFailure>()));
    expect(await store.list(recursive: true).where((f) => f is File).length, 1);
  });
  test(
      'mixed video, duplicate and missing duration records do not inflate songs',
      () async {
    final state = frame(['1000', '1000', '1001'], total: 2);
    final rows = state.details['456']!['data']['media_resources'] as List;
    rows.add({
      'type': 'video',
      'entity': {
        'video': {'id': '8000', 'duration': 100}
      }
    });
    rows.add({
      'type': 'track',
      'entity': {
        'track_wrapper': {
          'track': {'id': '1002', 'name': 'Placeholder', 'status': 30}
        }
      }
    });
    reader.state = state;
    final top = await library.browse({});
    expect(top['lists'][0]['cached'], 2);
    expect(top['lists'][0]['total'], 2);
  });
  test('N greater than M and missing M never manufacture completeness',
      () async {
    reader.state = frame(['1000', '1001'], total: 1);
    var top = await library.browse({});
    expect(top['lists'][0]['cached'], 2);
    expect(top['lists'][0]['total'], isNull);
    reader.state = frame(['1000'], total: null, revision: 'unknown');
    await library.refresh();
    top = await library.browse({});
    expect(top['lists'][0]['total'], isNull);
  });
  test('liked type1 is first without using a title heuristic', () async {
    final state = frame(['1000']);
    (state.catalog['data']['playlists'] as List).insert(0, {
      'id': '777',
      'title': 'AAAA regular',
      'type': 2,
      'resource_cnt': {'track_cnt': 1}
    });
    reader.state = state;
    final top = await library.browse({});
    expect(top['lists'][0]['liked'], true);
  });
  test('paged browse is bounded and invalid offsets/tokens fail', () async {
    reader.state = frame(List.generate(140, (i) => '${1000 + i}'), total: 140);
    final top = await library.browse({});
    final id = top['lists'][0]['id'];
    final one = await library.browse({'list': id});
    expect(one['page']['rows'], hasLength(100));
    expect(one['page']['nextOffset'], 100);
    final two = await library.browse({'list': id, 'offset': 100});
    expect(two['page']['rows'], hasLength(40));
    expect(two['page']['nextOffset'], isNull);
    await expectLater(library.browse({'list': id, 'offset': -1}),
        throwsA(isA<SodaLibraryFailure>()));
    await expectLater(
        library.browse({'list': '456'}), throwsA(isA<SodaLibraryFailure>()));
  });
  test('new source revision rejects a queued old command; no automatic retry',
      () async {
    final top = await library.browse({});
    final id = top['lists'][0]['id'];
    final view = await library.browse({'list': id});
    reader.state = frame(['1000'], revision: 'newsource', time: 4000);
    await expectLater(
        library.resolveTrack({
          'list': id,
          'snapshot': view['page']['snapshot'],
          'track': view['page']['rows'][0]['id'],
          'revision': view['revision']
        }),
        throwsA(isA<SodaLibraryFailure>()
            .having((e) => e.code, 'code', 'soda_stale_selection')));
  });
  test('sale label alone does not prove a cached song is unavailable',
      () async {
    final state = frame(['1000']);
    state.details['456']!['data']['media_resources'][0]['entity']
        ['track_wrapper']['track']['label_info'] = {'on_sale': true};
    reader.state = state;
    final top = await library.browse({});
    final view = await library.browse({'list': top['lists'][0]['id']});
    expect(view['page']['rows'][0]['playable'], true);
    expect(
        await library.resolveTrack({
          'list': view['list']['id'],
          'snapshot': view['page']['snapshot'],
          'track': view['page']['rows'][0]['id'],
          'revision': view['revision']
        }),
        '1000');
    final files =
        await store.list(recursive: true).where((f) => f is File).toList();
    expect(files.every((f) => f.path.length < store.path.length + 110), true,
        reason: 'Short history names leave Windows MAX_PATH margin');
  });

  test('cached blockers and unknown media types never launch', () async {
    final state = frame(['1000']);
    state.details['456']!['data']['media_resources'][0]['entity']
        ['track_wrapper']['track']['status'] = 10;
    reader.state = state;
    final top = await library.browse({});
    final id = top['lists'][0]['id'];
    final view = await library.browse({'list': id});
    expect(view['page']['rows'][0]['playable'], false);
    await expectLater(
        library.resolveTrack({
          'list': id,
          'snapshot': view['page']['snapshot'],
          'track': view['page']['rows'][0]['id'],
          'revision': view['revision']
        }),
        throwsA(isA<SodaLibraryFailure>()
            .having((e) => e.code, 'code', 'soda_track_unavailable')));
  });
  test(
      'partial cache does not create retry storms and concurrent reads coalesce',
      () async {
    await Future.wait(List.generate(8, (_) => library.browse({})));
    expect(reader.reads, 1);
    for (var i = 0; i < 5; i++) {
      await library.browse({});
    }
    expect(reader.reads, 1);
  });
  test('private snapshot retention survives restart without mixing accounts',
      () async {
    await library.refresh();
    reader.state = frame(['1000'], revision: 'new', time: 5000);
    await library.refresh();
    final restarted = SodaLibrary(reader: reader, storageDirectory: store);
    final top = await restarted.browse({});
    expect(top['lists'][0]['cached'], 1);
    expect(top['lists'][0]['historyCount'], 1);
  });
  test('history byte cap refuses growth without deleting older snapshots',
      () async {
    library = SodaLibrary(
        reader: reader, storageDirectory: store, historyByteLimit: 20000);
    await library.refresh();
    final previousFiles =
        await store.list(recursive: true).where((f) => f is File).length;
    final capped = SodaLibrary(
        reader: reader, storageDirectory: store, historyByteLimit: 1);
    reader.state = frame(['1000'], revision: 'shrink', time: 9000);
    await expectLater(
        capped.refresh(),
        throwsA(isA<SodaLibraryFailure>()
            .having((e) => e.code, 'code', 'soda_history_full')));
    expect(await store.list(recursive: true).where((f) => f is File).length,
        previousFiles);
  });

  test('play requires revision and refuses URL/path/shell payloads', () async {
    final top = await library.browse({});
    final view = await library.browse({'list': top['lists'][0]['id']});
    final valid = <String, dynamic>{
      'list': view['list']['id'],
      'snapshot': view['page']['snapshot'],
      'track': view['page']['rows'][0]['id'],
      'revision': view['revision']
    };
    final missing = {...valid}..remove('revision');
    await expectLater(
        library.resolveTrack(missing),
        throwsA(isA<SodaLibraryFailure>()
            .having((e) => e.code, 'code', 'soda_stale_selection')));
    for (final key in ['url', 'path', 'arguments']) {
      await expectLater(
          library.resolveTrack({...valid, key: 'untrusted'}),
          throwsA(isA<SodaLibraryFailure>()
              .having((e) => e.code, 'code', 'soda_invalid_selection')));
    }
  });

  test('retention write failure leaves previous private snapshot untouched',
      () async {
    await library.refresh();
    final blocked = File('${store.path}/blocked');
    await blocked.writeAsString('unrelated');
    final broken =
        SodaLibrary(reader: reader, storageDirectory: Directory(blocked.path));
    await expectLater(
        broken.refresh(),
        throwsA(isA<SodaLibraryFailure>()
            .having((e) => e.code, 'code', 'soda_history_write_failed')));
    expect(await blocked.readAsString(), 'unrelated');
    expect(
        await store
            .list(recursive: true)
            .where((f) => f is File && f.path.endsWith('.json'))
            .length,
        1);
  });
  group('search my songs', () {
    SodaCacheState named(Map<String, List<String>> songs) {
      final ids = songs.keys.toList();
      final state = frame(ids, total: ids.length);
      final resources = state.details['456']!['data']['media_resources'] as List;
      for (var i = 0; i < ids.length; i++) {
        final track = resources[i]['entity']['track_wrapper']['track'] as Map;
        track['name'] = songs[ids[i]]![0];
        track['artists'] = [
          {'name': songs[ids[i]]![1]}
        ];
      }
      return state;
    }

    test('every word must match title or artist, case-insensitively', () async {
      reader.state = named({
        '1000': ['Soft Rain', 'Night Band'],
        '1001': ['晴天', '周杰伦'],
        '1002': ['Rain Dance', 'Other'],
      });
      final rain = await library.browse({'query': 'rain'});
      expect((rain['search']['rows'] as List).map((r) => r['title']),
          ['Soft Rain', 'Rain Dance']);
      final both = await library.browse({'query': '  RAIN   night '});
      expect((both['search']['rows'] as List).map((r) => r['title']),
          ['Soft Rain']);
      expect(both['search']['query'], 'RAIN   night');
      final chinese = await library.browse({'query': '周杰伦'});
      expect((chinese['search']['rows'] as List).single['title'], '晴天');
      final none = await library.browse({'query': 'nothing here'});
      expect(none['search']['rows'], isEmpty);
      expect(none['list'], isNull);
      expect(none['page'], isNull);
    });

    test('iPad curly apostrophes and quotes match straight ones', () async {
      reader.state = named({
        '1000': ["Don't Stop", 'Band'],
        '1001': ['Say “Hi”', 'Band'],
      });
      final curly = await library.browse({'query': 'don’t'});
      expect((curly['search']['rows'] as List).single['title'], "Don't Stop");
      final quoted = await library.browse({'query': '"hi"'});
      expect((quoted['search']['rows'] as List).single['title'],
          'Say “Hi”');
    });

    test('a found song plays through the normal resolve path', () async {
      reader.state = named({
        '1000': ['Soft Rain', 'Night Band'],
      });
      final found = await library.browse({'query': 'soft'});
      final row = (found['search']['rows'] as List).single;
      final id = await library.resolveTrack({
        'list': row['list'],
        'snapshot': row['snapshot'],
        'track': row['id'],
        'revision': found['revision'],
      });
      expect(id, '1000');
      expect(jsonEncode(found), isNot(contains('"1000"')),
          reason: 'provider ids never leave the laptop');
    });

    test('results are bounded and say there are more', () async {
      reader.state =
          named({for (var i = 0; i < 70; i++) '${1000 + i}': ['Song $i', 'Band']});
      final found = await library.browse({'query': 'song'});
      expect(found['search']['rows'], hasLength(SodaLibrary.searchLimit));
      expect(found['search']['more'], true);
    });

    test('invalid queries are refused', () async {
      for (final bad in [
        {'query': ''},
        {'query': '   '},
        {'query': 7},
        {'query': 'x' * 121},
        {'query': 'rain', 'list': 'abc'},
      ]) {
        await expectLater(library.browse(bad), throwsA(isA<SodaLibraryFailure>()),
            reason: '$bad');
      }
    });
  });

}

class FakeReader extends SodaCacheReader {
  FakeReader(this.state) : super(root: Directory.systemTemp);
  SodaCacheState state;
  SodaCacheFailure? failure;
  int reads = 0;
  @override
  bool get available => true;
  @override
  Future<String> readAccount() async {
    if (failure != null) throw failure!;
    return state.accountId;
  }

  @override
  Future<SodaCacheState> read() async {
    reads++;
    await Future<void>.delayed(Duration.zero);
    if (failure != null) throw failure!;
    return state;
  }
}

SodaCacheState frame(List<String> ids,
    {String account = '123',
    String revision = 'initial',
    int time = 1000,
    int? total = 33}) {
  final playlist = {
    'id': '456',
    'title': 'Synthetic liked',
    'type': 1,
    'resource_cnt': {'track_cnt': total}
  };
  return SodaCacheState(accountId: account, revision: revision, catalog: {
    'time': time,
    'data': {
      'playlists': [playlist]
    }
  }, details: {
    '456': {
      'time': time,
      'data': {
        'playlist': playlist,
        'media_resources': [
          for (final id in ids)
            {
              'type': 'track',
              'entity': {
                'track_wrapper': {
                  'track': {
                    'id': id,
                    'name': 'Synthetic song',
                    'duration': 180000,
                    'media_type': 'track',
                    'vid': 'synthetic-media',
                    'artists': [
                      {'name': 'Synthetic artist'}
                    ],
                  }
                }
              }
            },
        ]
      }
    }
  });
}
