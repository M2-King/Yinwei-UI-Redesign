import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/soda_cache_reader.dart';
import 'package:yinwei_player/remote/soda_library.dart';

import 'soda_library_test.dart' show FakeReader, frame;

void main() {
  late Directory store;
  late FakeReader reader;
  late SodaLibrary library;
  late DateTime now;
  late Map<String, dynamic> payload;
  setUp(() async {
    store = await Directory.systemTemp.createTemp('soda-revalidate-');
    reader = FakeReader(frame(['1000']));
    now = DateTime.utc(2026, 10, 24);
    library =
        SodaLibrary(reader: reader, storageDirectory: store, clock: () => now);
    final top = await library.browse({});
    final id = top['lists'][0]['id'];
    final view = await library.browse({'list': id});
    payload = {
      'list': id,
      'snapshot': view['page']['snapshot'],
      'track': view['page']['rows'][0]['id'],
      'revision': view['revision']
    };
    await library.resolveTrack(payload);
  });
  tearDown(() => store.delete(recursive: true));

  test('final revalidation does not repeat a fresh full cache read', () async {
    final reads = reader.reads;
    expect(await library.resolveTrack(payload, revalidate: true), '1000');
    expect(reader.reads, reads);
  });

  test('account switch during launcher wait refuses old handles', () async {
    reader.state = frame(['1000'], account: '999', revision: 'changed');
    await expectLater(library.resolveTrack(payload, revalidate: true),
        throwsA(isA<SodaLibraryFailure>()));
  });

  test('logout or failed account fence never reuses the old snapshot',
      () async {
    reader.failure = const SodaCacheFailure('soda_no_account');
    await expectLater(library.resolveTrack(payload, revalidate: true),
        throwsA(isA<SodaLibraryFailure>()));
  });

  test('slow launcher identity check refreshes and rejects removed songs',
      () async {
    final reads = reader.reads;
    now = now.add(const Duration(seconds: 1));
    reader.state = frame(['2000'], revision: 'changed', time: 4000);
    await expectLater(library.resolveTrack(payload, revalidate: true),
        throwsA(isA<SodaLibraryFailure>()));
    expect(reader.reads, reads + 1);
  });

  test('ordinary selections always refresh even within the reuse window',
      () async {
    final reads = reader.reads;
    expect(await library.resolveTrack(payload), '1000');
    expect(reader.reads, reads + 1);
  });
}
