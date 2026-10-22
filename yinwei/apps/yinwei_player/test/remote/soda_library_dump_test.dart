import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/soda_cache_reader.dart';
import '../../tool/soda_library_dump.dart';
import 'soda_library_test.dart' as fixture;

void main() {
  test('browse/list/query use app JSON and keep opaque session handles',
      () async {
    final reader = fixture.FakeReader(fixture.frame(['1000', '1001']));
    final preview = PreviewLibrary(reader: reader);
    final top = await preview.browse({});
    expect(top['lists'][0]['title'], 'Synthetic liked');
    final selected = await preview.browse({'list': top['lists'][0]['id']});
    expect(selected['page']['rows'], hasLength(2));
    expect(selected['revision'], top['revision']);
    final search = await preview.browse({'query': 'synthetic song'});
    expect(search['search']['rows'], hasLength(2));
    final wire = jsonEncode(selected);
    for (final private in [
      'accountId',
      'providerId',
      '"1000"',
      '"456"',
      'vid'
    ]) {
      expect(wire, isNot(contains(private)));
    }
  });
  test('history stays in memory, shrink keeps older snapshot without union',
      () async {
    final reader = fixture.FakeReader(
        fixture.frame(List.generate(31, (i) => '${1000 + i}')));
    final preview = PreviewLibrary(reader: reader);
    final store = preview.library.storageDirectory;
    final existed = Directory(store.path).existsSync();
    final top = await preview.browse({});
    final id = top['lists'][0]['id'];
    final old = await preview.browse({'list': id});
    reader.state =
        fixture.frame(['1000', '1001'], revision: 'next', time: 2000);
    await preview.memory(() => preview.library.refresh());
    final latest = await preview.browse({'list': id});
    expect(latest['list']['cached'], 2);
    expect(latest['list']['total'], 33);
    expect(latest['list']['historyCount'], 1);
    final historical =
        await preview.browse({'list': id, 'snapshot': old['page']['snapshot']});
    expect(historical['page']['rows'], hasLength(31));
    expect(
        historical['page']['rows'].every((dynamic r) => r['playable'] == false),
        true);
    expect(Directory(store.path).existsSync(), existed);
    expect(existed, false,
        reason: 'Virtual history directory must never be created');
  });
  test('missing/corrupt/schema-changed source yields only a safe error',
      () async {
    final reader = fixture.FakeReader(fixture.frame([]));
    final preview = PreviewLibrary(reader: reader);
    for (final code in [
      'soda_unavailable',
      'soda_source_corrupt',
      'soda_source_unsupported'
    ]) {
      reader.failure = SodaCacheFailure(code);
      expect(await preview.browse({}), {'error': code});
    }
  });
  test('invalid selections/URLs/paths rejected, no playback API', () async {
    final preview =
        PreviewLibrary(reader: fixture.FakeReader(fixture.frame([])));
    for (final bad in [
      {'url': 'luna://play'},
      {'path': 'C:\\secret'},
      {'offset': -1},
      {'offset': '0'},
      {'query': 7},
      {'query': 'x' * 161}
    ]) {
      expect(await preview.browse(bad), {'error': 'soda_invalid_selection'});
    }
    expect((await preview.browse({'list': 'unknown'}))['error'],
        'soda_invalid_selection');
  });
  test('virtual storage denies any unexpected disk access', () async {
    final preview =
        PreviewLibrary(reader: fixture.FakeReader(fixture.frame([])));
    await expectLater(
        preview.memory(() async => File('unexpected-write').writeAsString('x')),
        throwsStateError);
  });
}
