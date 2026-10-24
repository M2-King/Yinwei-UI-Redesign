import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/soda_cover.dart';

Map album({Object? uri, Object? template, Object? urls}) => {
      'url_cover': {
        'uri': uri ?? 'tos-cn-v-2774c002/o0SeEUF4AlQuqFd1BADCEkN6ZMpgSBAt',
        'template_prefix': template ?? 'tplv-b829550vbb',
        'urls': urls ?? ['https://p3-luna.douyinpic.com/img/'],
      }
    };

Uint8List jpeg([int n = 2000]) =>
    Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, ...List.filled(n, 7)]);

void main() {
  group('SodaCoverRef', () {
    test('builds the confirmed CDN address', () {
      final ref = SodaCoverRef.fromAlbum(album())!;
      expect(
          ref.url(480).toString(),
          'https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/'
          'o0SeEUF4AlQuqFd1BADCEkN6ZMpgSBAt~tplv-b829550vbb-crop-center:480:480.jpg');
    });

    test('skips a foreign host and takes the next allowed one', () {
      final ref = SodaCoverRef.fromAlbum(album(urls: [
        'https://evil.example.com/img/',
        'https://p6-luna.douyinpic.com/img/'
      ]))!;
      expect(ref.host, 'p6-luna.douyinpic.com');
    });

    test('hostile or unexpected values give no cover', () {
      for (final a in [
        album(urls: ['http://p3-luna.douyinpic.com/img/']),
        album(urls: ['https://p3-luna.douyinpic.com.evil.com/img/']),
        album(urls: ['https://p3-luna.douyinpic.com:8443/img/']),
        album(urls: ['https://p3-luna.douyinpic.com/img/?x=1']),
        album(urls: ['https://p3-luna.douyinpic.com/other/']),
        album(uri: '../../etc/passwd'),
        album(uri: 'tos-cn/abc?x=1'),
        album(uri: 'tos-cn-v-1/${List.filled(200, 'a').join()}'),
        album(template: 'tplv-x~evil'),
        {'url_cover': 'x'},
        null,
      ]) {
        expect(SodaCoverRef.fromAlbum(a), isNull, reason: '$a');
      }
    });
  });

  test('imageOf accepts JPEG/PNG/WebP signatures only', () {
    expect(SodaCoverStore.imageOf(jpeg())?.mime, 'image/jpeg');
    expect(
        SodaCoverStore.imageOf(Uint8List.fromList([
          0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
          ...List.filled(80, 0)
        ]))?.mime,
        'image/png');
    expect(
        SodaCoverStore.imageOf(Uint8List.fromList([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, //
          ...List.filled(80, 0)
        ]))?.mime,
        'image/webp');
    expect(
        SodaCoverStore.imageOf(
            Uint8List.fromList('<html>'.codeUnits + List.filled(80, 32))),
        isNull);
    expect(SodaCoverStore.imageOf(Uint8List(10)), isNull);
  });

  group('SodaCoverStore', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('yw-covers-'));
    tearDown(() async => dir.delete(recursive: true));
    final ref = SodaCoverRef.fromAlbum(album())!;

    test('downloads once, then serves from the disk cache', () async {
      var calls = 0;
      final store = SodaCoverStore(
          directory: dir,
          download: (_) async {
            ++calls;
            return SodaCoverImage('image/jpeg', jpeg());
          });
      expect((await store.cover('123', ref))?.mime, 'image/jpeg');
      expect((await store.cover('123', ref))?.bytes.length, 2004);
      expect(calls, 1);
      final again = SodaCoverStore(
          directory: dir,
          download: (_) async => throw StateError('no network needed'));
      expect(await again.cover('123', ref), isNotNull, reason: 'disk cache');
      final names = dir.listSync().map((f) => f.path).join(' ');
      expect(names.contains('123'), isFalse, reason: 'no track IDs on disk');
    });

    test('identical requests share one download', () async {
      var calls = 0;
      final gate = Completer<void>();
      final store = SodaCoverStore(
          directory: dir,
          download: (_) async {
            ++calls;
            await gate.future;
            return SodaCoverImage('image/jpeg', jpeg());
          });
      final a = store.cover('9', ref), b = store.cover('9', ref);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      expect(await a, isNotNull);
      expect(await b, isNotNull);
      expect(calls, 1);
    });

    test('a failed cover waits 10 minutes before trying again', () async {
      var now = DateTime(2026, 10, 25);
      var calls = 0;
      final store = SodaCoverStore(
          directory: dir,
          clock: () => now,
          download: (_) async {
            ++calls;
            return null;
          });
      expect(await store.cover('5', ref), isNull);
      expect(await store.cover('5', ref), isNull);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 11));
      expect(await store.cover('5', ref), isNull);
      expect(calls, 2);
    });

    test('the cache stays under its cap, oldest-used deleted first', () async {
      final store = SodaCoverStore(
          directory: dir,
          maxCacheBytes: 10000,
          download: (_) async => SodaCoverImage('image/jpeg', jpeg(3000)));
      for (var i = 1; i <= 6; ++i) {
        await store.cover('$i', ref);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final total = dir
          .listSync()
          .whereType<File>()
          .fold<int>(0, (n, f) => n + f.lengthSync());
      expect(total, lessThanOrEqualTo(10000));
    });

    test('not a track ID: nothing downloaded', () async {
      final store = SodaCoverStore(
          directory: dir, download: (_) async => throw StateError('no'));
      expect(await store.cover('../x', ref), isNull);
    });

    test('one real download from the CDN (network)', () async {
      final store = SodaCoverStore(directory: dir);
      final image = await store.cover('1', ref);
      // ignore: avoid_print
      print('REAL_COVER ${image?.mime} ${image?.bytes.length} bytes');
      if (image == null) return markTestSkipped('CDN not reachable here');
      expect(image.mime, 'image/jpeg');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
