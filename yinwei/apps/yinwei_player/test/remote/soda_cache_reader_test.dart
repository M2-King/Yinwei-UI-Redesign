import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/soda_cache_reader.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('soda-reader-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('independent fixture CRC32C vector', () {
    expect(crc32c(utf8.encode('123456789')), 0xe3069283);
  });
  test('worker deadline terminates work and a fresh snapshot read can recover',
      () async {
    await Fixture(root).write();
    final watch = Stopwatch()..start();
    await expectLater(
        SodaCacheReader(root: root, timeout: const Duration(microseconds: 1))
            .read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_source_busy')));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect((await SodaCacheReader(root: root).read()).accountId, '123');
  });
  test('source file limit is checked before copying its contents', () async {
    final f = Fixture(root);
    await f.write();
    final table = File('${f.db.path}/000002.ldb');
    final tableFile = await table.open(mode: FileMode.write);
    await tableFile.truncate(65 * 1024 * 1024);
    await tableFile.close();
    await expectLater(
        SodaCacheReader(root: root).read(), throwsA(isA<SodaCacheFailure>()));
  });
  test('reads manifest live tables only, checked Snappy and WAL puts',
      () async {
    final f = Fixture(root);
    await f.write(compressed: true);
    // This obsolete table is intentionally corrupt and must never be opened.
    await File('${f.db.path}/000099.ldb').writeAsBytes([1, 2, 3]);
    final state = await SodaCacheReader(root: root).read();
    expect(state.accountId, '123');
    expect((state.catalog['data']['playlists'] as List).length, 1);
    expect(state.details['456']!['time'], 2000);
    expect(File('${f.db.path}/LOCK').existsSync(), false);
  });
  test(
      'a newer tombstone hides a table value; obsolete account cannot supply catalog',
      () async {
    final f = Fixture(root);
    await f.write(deleteDetail: true);
    expect((await SodaCacheReader(root: root).read()).details, isEmpty);
    await f.account('999');
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_unavailable')));
  });
  test(
      'catalog and source account are mandatory; logout does not pick another cached UID',
      () async {
    final f = Fixture(root);
    await f.write();
    await f.account(null);
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_no_account')));
  });
  test('manifest deleted files stay deleted even if their SSTables remain',
      () async {
    final f = Fixture(root);
    await f.write(deleteLiveTable: true, deleteDetail: true);
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_unavailable')));
  });
  test('WAL complete prefix survives an incomplete last physical record',
      () async {
    final f = Fixture(root);
    await f.write();
    final wal = File('${f.db.path}/000003.log');
    await wal.writeAsBytes([0, 0, 0, 0, 20, 0, 1, 8, 8], mode: FileMode.append);
    expect((await SodaCacheReader(root: root).read()).details['456']!['time'],
        2000);
  });
  test('fragmented WAL write batch is reassembled before being accepted',
      () async {
    final f = Fixture(root);
    await f.write(large: true);
    final result = await SodaCacheReader(root: root).read();
    expect(result.details['456']!['data']['padding'], hasLength(50000));
  });
  for (final target in ['MANIFEST-000001', '000002.ldb', '000003.log']) {
    test('rejects checksum corruption in $target', () async {
      final f = Fixture(root);
      await f.write();
      final file = File('${f.db.path}/$target');
      final b = await file.readAsBytes();
      b[target.endsWith('ldb') ? 3 : 7] ^= 1;
      await file.writeAsBytes(b);
      await expectLater(
          SodaCacheReader(root: root).read(),
          throwsA(isA<SodaCacheFailure>()
              .having((e) => e.code, 'code', 'soda_source_corrupt')));
    });
  }
  test('Snappy declared allocation is bounded before allocating', () async {
    final f = Fixture(root);
    await f.write(snappyBomb: true);
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_source_unsupported')));
  });
  test('Snappy copy records preserve overlapping/back references', () async {
    final f = Fixture(root);
    await f.write(snappyCopy: true);
    expect((await SodaCacheReader(root: root).read()).details, contains('456'));
  });
  test(
      'Snappy zero-offset copy is rejected before reading uninitialized output',
      () async {
    final f = Fixture(root);
    await f.write(snappyBadCopy: true);
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_source_corrupt')));
  });
  test('read leaves all synthetic source bytes and file set unchanged',
      () async {
    final f = Fixture(root);
    await f.write();
    Future<Map<String, String>> capture() async => {
          for (final file in await root
              .list(recursive: true)
              .where((e) => e is File)
              .cast<File>()
              .toList())
            file.path: base64Encode(await file.readAsBytes()),
        };
    final before = await capture();
    await SodaCacheReader(root: root).read();
    expect(await capture(), before);
  });
  test('manifest pathname traversal and unknown comparator fail closed',
      () async {
    final f = Fixture(root);
    await f.write();
    await File('${f.db.path}/CURRENT').writeAsString('../MANIFEST-000001\n');
    await expectLater(
        SodaCacheReader(root: root).read(), throwsA(isA<SodaCacheFailure>()));
    await f.write(comparator: 'other.Comparator');
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_source_unsupported')));
  });
  test('malformed matching cache JSON does not become an empty successful list',
      () async {
    final f = Fixture(root);
    await f.write(badJson: true);
    await expectLater(
        SodaCacheReader(root: root).read(),
        throwsA(isA<SodaCacheFailure>()
            .having((e) => e.code, 'code', 'soda_source_corrupt')));
  });
}

List<int> vi(int n) {
  final out = <int>[];
  do {
    final part = n & 127;
    n >>= 7;
    out.add(part | (n > 0 ? 128 : 0));
  } while (n > 0);
  return out;
}

List<int> u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
List<int> u64(int n) =>
    (ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List();
List<int> field(List<int> b) => [...vi(b.length), ...b];
List<int> storageKey(String key) =>
    [...ascii.encode('_app://resources'), 0, 1, ...ascii.encode(key)];
List<int> value(Object o) {
  final s = jsonEncode(o);
  return [
    0,
    for (final c in s.codeUnits) ...[c & 255, c >> 8]
  ];
}

int crc32c(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (crc.isOdd ? 0x82f63b78 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int mask(int n) =>
    (((n >> 15) | ((n << 17) & 0xffffffff)) + 0xa282ead8) & 0xffffffff;
List<int> physical(int kind, List<int> payload) => [
      ...u32(mask(crc32c([kind, ...payload]))),
      payload.length & 255,
      payload.length >> 8,
      kind,
      ...payload,
    ];
List<int> log(List<int> payload) {
  final result = <int>[];
  var p = 0, first = true;
  do {
    final capacity = 32768 - result.length % 32768 - 7;
    if (capacity < 0) {
      result.addAll(List.filled(capacity + 7, 0));
      continue;
    }
    final count = (payload.length - p).clamp(0, capacity);
    final end = p + count == payload.length;
    result.addAll(physical(
        first ? (end ? 1 : 2) : (end ? 4 : 3), payload.sublist(p, p + count)));
    p += count;
    first = false;
  } while (p < payload.length);
  return result;
}

List<int> entriesBlock(List<(List<int>, List<int>)> entries) => [
      for (final e in entries) ...[
        0,
        ...vi(e.$1.length),
        ...vi(e.$2.length),
        ...e.$1,
        ...e.$2
      ],
      ...u32(0),
      ...u32(1),
    ];
List<int> literalSnappy(List<int> input) {
  final n = input.length - 1;
  final width = n < 256
      ? 1
      : n < 65536
          ? 2
          : 3;
  return [
    ...vi(input.length),
    if (n < 60)
      n << 2
    else ...[
      (59 + width) << 2,
      for (var i = 0; i < width; i++) (n >> (8 * i)) & 255,
    ],
    ...input
  ];
}

List<int> table(List<(List<int>, List<int>)> entries,
    {bool compressed = false,
    bool snappyBomb = false,
    bool snappyCopy = false,
    bool snappyBadCopy = false}) {
  final file = <int>[];
  List<int> append(List<int> data, int kind) {
    final handle = [...vi(file.length), ...vi(data.length)];
    file.addAll([
      ...data,
      kind,
      ...u32(mask(crc32c([...data, kind])))
    ]);
    return handle;
  }

  final raw = entriesBlock(entries);
  final prefix = raw.sublist(0, raw.length - 7);
  final copyPayload = [
    ...vi(raw.length),
    ...literalSnappy(prefix).skip(vi(prefix.length).length),
    10,
    1,
    0,
    0,
    1,
    10,
    5,
    0
  ];
  final data = append(
      snappyBadCopy
          ? [8, 2, 0, 0]
          : snappyCopy
              ? copyPayload
              : snappyBomb
                  ? vi(32 * 1024 * 1024)
                  : compressed
                      ? literalSnappy(raw)
                      : raw,
      snappyBomb || compressed || snappyCopy || snappyBadCopy ? 1 : 0);
  final meta = append(entriesBlock([]), 0);
  final index = append(
      entriesBlock([
        ([255], data)
      ]),
      0);
  final handles = [...meta, ...index];
  file.addAll([
    ...handles,
    ...List.filled(40 - handles.length, 0),
    0x57,
    0xfb,
    0x80,
    0x8b,
    0x24,
    0x75,
    0x47,
    0xdb
  ]);
  return file;
}

class Fixture {
  Fixture(this.root);
  final Directory root;
  Directory get db => Directory('${root.path}/Local Storage/leveldb');
  Future<void> account(String? id) async {
    final dir = Directory('${root.path}/LunaStorage');
    await dir.create(recursive: true);
    await File('${dir.path}/Config').writeAsBytes([
      76,
      85,
      78,
      65,
      ...gzip.encode(utf8.encode(jsonEncode({
        'userInfoStateCache': id == null
            ? null
            : {
                'my_info': {'id': id}
              }
      })))
    ]);
  }

  Future<void> write(
      {bool compressed = false,
      bool deleteDetail = false,
      bool deleteLiveTable = false,
      bool large = false,
      bool snappyBomb = false,
      bool snappyCopy = false,
      bool snappyBadCopy = false,
      bool badJson = false,
      String comparator = 'leveldb.BytewiseComparator'}) async {
    await account('123');
    await db.create(recursive: true);
    final catalog = {
      'time': 1000,
      'data': {
        'playlists': [
          {'id': '456', 'title': 'Synthetic list', 'type': 1}
        ]
      }
    };
    final detail = {
      'time': 1000,
      'data': {
        'playlist': {'id': '456'},
        'media_resources': []
      }
    };
    final ck = storageKey('useRequestCache:playlists:123');
    final dk = storageKey('useRequestCache:playlist_detail:456');
    final bytes = table([
      ([...ck, ...u64((1 << 8) | 1)], badJson ? [1, 123] : value(catalog)),
      ([...dk, ...u64((2 << 8) | 1)], value(detail)),
    ],
        compressed: compressed,
        snappyBomb: snappyBomb,
        snappyCopy: snappyCopy,
        snappyBadCopy: snappyBadCopy);
    await File('${db.path}/000002.ldb').writeAsBytes(bytes);
    final manifest = [
      1,
      ...field(ascii.encode(comparator)),
      2,
      3,
      3,
      4,
      4,
      2,
      7,
      0,
      2,
      ...vi(bytes.length),
      ...field([...ck, ...u64(257)]),
      ...field([...dk, ...u64(513)]),
      if (deleteLiveTable) ...[6, 0, 2],
    ];
    await File('${db.path}/MANIFEST-000001').writeAsBytes(log(manifest));
    await File('${db.path}/CURRENT').writeAsString('MANIFEST-000001\n');
    detail['time'] = 2000;
    if (large) {
      (detail['data'] as Map)['padding'] = List.filled(50000, 'x').join();
    }
    final batch = [
      ...u64(10),
      ...u32(1),
      deleteDetail ? 0 : 1,
      ...field(dk),
      if (!deleteDetail) ...field(value(detail))
    ];
    await File('${db.path}/000003.log').writeAsBytes(log(batch));
  }
}
