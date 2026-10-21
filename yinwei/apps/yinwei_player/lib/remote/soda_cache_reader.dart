import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Provider metadata only. Never opens a database, its LOCK, a media file or a
/// credential store. Account identifiers stay on the laptop.
class SodaCacheState {
  const SodaCacheState({
    required this.accountId,
    required this.revision,
    required this.catalog,
    required this.details,
  });
  final String accountId, revision;
  final Map<String, dynamic> catalog;
  final Map<String, Map<String, dynamic>> details;
}

class SodaCacheFailure implements Exception {
  const SodaCacheFailure(this.code);
  final String code;
  @override
  String toString() => 'SodaCacheFailure($code)';
}

class SodaCacheReader {
  SodaCacheReader({Directory? root, this.timeout = const Duration(seconds: 4)})
      : root = root ?? _defaultRoot(),
        _supported = root != null || Platform.isWindows;
  final Directory root;
  final bool _supported;
  final Duration timeout;
  static Directory _defaultRoot() => Directory(
      '${Platform.environment['APPDATA'] ?? ''}${Platform.pathSeparator}SodaMusic');
  bool get available => _supported && root.existsSync();

  /// Cheap account-only fence for debounced browse responses. This reads the
  /// cached noncredential marker; it is not a claim of a live provider login.
  Future<String> readAccount() async {
    if (!available) throw const SodaCacheFailure('soda_unavailable');
    final path = root.absolute.path;
    try {
      return await _bounded<String>(path, true);
    } on SodaCacheFailure {
      rethrow;
    } catch (_) {
      throw const SodaCacheFailure('soda_source_busy');
    }
  }

  Future<SodaCacheState> read() async {
    if (!available) throw const SodaCacheFailure('soda_unavailable');
    final path = root.absolute.path;
    return _bounded<SodaCacheState>(path, false);
  }

  Future<T> _bounded<T>(String path, bool accountOnly) async {
    final reply = ReceivePort();
    final result = Completer<T>();
    Isolate? worker;
    final subscription = reply.listen((message) {
      if (result.isCompleted) return;
      if (message is List && message.length == 2 && message[0] == 'ok') {
        result.complete(message[1] as T);
      } else {
        final code =
            message is List && message.length == 2 && message[1] is String
                ? message[1] as String
                : 'soda_source_corrupt';
        result.completeError(SodaCacheFailure(code));
      }
    });
    final timer = Timer(timeout, () {
      worker?.kill(priority: Isolate.immediate);
      if (!result.isCompleted) {
        result.completeError(const SodaCacheFailure('soda_source_busy'));
      }
    });
    unawaited(Isolate.spawn(_cacheWorker, (reply.sendPort, path, accountOnly))
        .then((isolate) {
      worker = isolate;
      if (result.isCompleted) isolate.kill(priority: Isolate.immediate);
    }, onError: (Object _) {
      if (!result.isCompleted) {
        result.completeError(const SodaCacheFailure('soda_source_busy'));
      }
    }));
    try {
      return await result.future;
    } finally {
      timer.cancel();
      worker?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      reply.close();
    }
  }
}

void _cacheWorker((SendPort, String, bool) request) {
  try {
    request.$1
        .send(['ok', request.$3 ? _account(request.$2) : _capture(request.$2)]);
  } on SodaCacheFailure catch (e) {
    request.$1.send(['error', e.code]);
  } catch (_) {
    request.$1.send(['error', 'soda_source_corrupt']);
  }
}

const _fileLimit = 64 * 1024 * 1024;
const _blockLimit = 16 * 1024 * 1024;
const _jsonLimit = 16 * 1024 * 1024;
const _entryLimit = 250000;
const _sequenceLimit = 0x00ffffffffffffff;

Never _bad() => throw const SodaCacheFailure('soda_source_corrupt');
Never _unsupported() => throw const SodaCacheFailure('soda_source_unsupported');

class _Changed implements Exception {}

Uint8List _read(String path, [int limit = _fileLimit]) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw _Changed();
  }
  final file = File(path).openSync(mode: FileMode.read);
  try {
    final size = file.lengthSync();
    if (size < 0 || size > limit) _unsupported();
    final bytes = file.readSync(size);
    if (bytes.length != size) throw _Changed();
    return bytes;
  } finally {
    file.closeSync();
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int position = 0;
  bool get done => position == bytes.length;
  int byte() {
    if (position >= bytes.length) _bad();
    return bytes[position++];
  }

  int varint() {
    var value = 0;
    for (var shift = 0; shift < 63; shift += 7) {
      final b = byte();
      value |= (b & 127) << shift;
      if (b < 128) return value;
    }
    _bad();
  }

  Uint8List take(int length) {
    if (length < 0 || length > bytes.length - position) _bad();
    final result = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return result;
  }

  Uint8List slice() => take(varint());
  int uint32() => ByteData.sublistView(take(4)).getUint32(0, Endian.little);
  int uint64() {
    final value = ByteData.sublistView(take(8)).getUint64(0, Endian.little);
    if (value < 0) _bad();
    return value;
  }
}

// CRC32C, not IEEE CRC32. LevelDB masks the result stored in each block/log.
final _crcTable = List<int>.generate(256, (i) {
  var n = i;
  for (var j = 0; j < 8; j++) {
    n = (n >> 1) ^ ((n & 1) != 0 ? 0x82f63b78 : 0);
  }
  return n;
});
int _crc(Iterable<int> bytes) {
  var n = 0xffffffff;
  for (final byte in bytes) {
    n = _crcTable[(n ^ byte) & 255] ^ (n >> 8);
  }
  return (n ^ 0xffffffff) & 0xffffffff;
}

int _masked(int crc) =>
    (((crc >> 15) | ((crc << 17) & 0xffffffff)) + 0xa282ead8) & 0xffffffff;

List<Uint8List> _logRecords(Uint8List bytes, {required bool manifest}) {
  final result = <Uint8List>[];
  BytesBuilder? fragments;
  var position = 0;
  var fragmentedBytes = 0;
  while (position < bytes.length) {
    final remaining = 32768 - position % 32768;
    if (remaining < 7) {
      final end = (position + remaining).clamp(0, bytes.length);
      if (bytes.sublist(position, end).any((n) => n != 0)) _bad();
      position = end;
      continue;
    }
    if (position + 7 > bytes.length) {
      if (manifest) throw _Changed();
      break;
    }
    final header =
        _Cursor(Uint8List.sublistView(bytes, position, position + 7));
    final checksum = header.uint32();
    final length = header.byte() | (header.byte() << 8);
    final kind = header.byte();
    if (kind == 0 && length == 0 && checksum == 0) {
      final end = (position + remaining).clamp(0, bytes.length);
      if (bytes.sublist(position, end).any((n) => n != 0)) _bad();
      position = end;
      continue;
    }
    if (length > remaining - 7) _bad();
    if (position + 7 + length > bytes.length) {
      if (manifest) throw _Changed();
      break;
    }
    final data =
        Uint8List.sublistView(bytes, position + 7, position + 7 + length);
    if (_masked(_crc([kind].followedBy(data))) != checksum) _bad();
    position += 7 + length;
    switch (kind) {
      case 1:
        if (fragments != null) _bad();
        result.add(data);
      case 2:
        if (fragments != null) _bad();
        fragments = BytesBuilder(copy: false)..add(data);
        fragmentedBytes = data.length;
      case 3:
      case 4:
        if (fragments == null) _bad();
        fragmentedBytes += data.length;
        if (fragmentedBytes > _fileLimit) _unsupported();
        fragments.add(data);
        if (kind == 4) {
          result.add(fragments.takeBytes());
          fragments = null;
        }
      default:
        _unsupported();
    }
    if (result.length > _entryLimit) _unsupported();
  }
  if (manifest && fragments != null) throw _Changed();
  return result;
}

class _Version {
  final files = <int, ({int level, int size})>{};
  int log = 0, previousLog = 0;
  bool comparatorSeen = false;
  void edit(Uint8List bytes) {
    final c = _Cursor(bytes);
    while (!c.done) {
      switch (c.varint()) {
        case 1:
          if (utf8.decode(c.slice()) != 'leveldb.BytewiseComparator') {
            _unsupported();
          }
          comparatorSeen = true;
        case 2:
          log = c.varint();
        case 3:
        case 4:
          c.varint();
        case 5:
          c.varint();
          c.slice();
        case 6:
          final level = c.varint(), number = c.varint();
          if (files[number]?.level == level) files.remove(number);
        case 7:
          final level = c.varint(), number = c.varint(), size = c.varint();
          c.slice();
          c.slice();
          if (level > 31 || number <= 0 || size > _fileLimit) _unsupported();
          files[number] = (level: level, size: size);
          if (files.length > 4096) _unsupported();
        case 9:
          previousLog = c.varint();
        default:
          _unsupported();
      }
    }
  }
}

Uint8List _snappy(Uint8List bytes) {
  final c = _Cursor(bytes);
  final length = c.varint();
  if (length > _blockLimit) _unsupported();
  final out = Uint8List(length);
  var position = 0;
  while (!c.done) {
    final tag = c.byte(), kind = tag & 3;
    int count, offset;
    if (kind == 0) {
      count = tag >> 2;
      if (count >= 60) {
        final width = count - 59;
        count = 0;
        for (var i = 0; i < width; i++) {
          count |= c.byte() << (8 * i);
        }
      }
      count++;
      if (count > out.length - position) _bad();
      out.setRange(position, position + count, c.take(count));
      position += count;
    } else {
      if (kind == 1) {
        count = 4 + ((tag >> 2) & 7);
        offset = ((tag & 224) << 3) | c.byte();
      } else {
        count = 1 + (tag >> 2);
        offset = 0;
        for (var i = 0; i < (kind == 2 ? 2 : 4); i++) {
          offset |= c.byte() << (8 * i);
        }
      }
      if (offset <= 0 || offset > position || count > out.length - position) {
        _bad();
      }
      for (var i = 0; i < count; i++) {
        out[position] = out[position - offset];
        position++;
      }
    }
  }
  if (position != length) _bad();
  return out;
}

({int offset, int size}) _handle(_Cursor c) =>
    (offset: c.varint(), size: c.varint());
Uint8List _block(Uint8List file, ({int offset, int size}) h) {
  if (h.offset < 0 ||
      h.size > _blockLimit ||
      h.offset > file.length - 5 ||
      h.size > file.length - h.offset - 5) {
    _bad();
  }
  final value = Uint8List.sublistView(file, h.offset, h.offset + h.size);
  final kind = file[h.offset + h.size];
  final checksum = _Cursor(Uint8List.sublistView(
          file, h.offset + h.size + 1, h.offset + h.size + 5))
      .uint32();
  if (_masked(_crc(value.followedBy([kind]))) != checksum) _bad();
  if (kind == 0) return value;
  if (kind == 1) return _snappy(value);
  _unsupported();
}

List<MapEntry<Uint8List, Uint8List>> _entries(Uint8List block) {
  if (block.length < 8) _bad();
  final count =
      _Cursor(Uint8List.sublistView(block, block.length - 4)).uint32();
  if (count < 1 || count > (block.length - 4) ~/ 4) _bad();
  final end = block.length - 4 - count * 4;
  final restarts = _Cursor(Uint8List.sublistView(block, end, block.length - 4));
  final points = <int>{};
  var last = -1;
  for (var i = 0; i < count; i++) {
    final point = restarts.uint32();
    if (point < last || point > end || (i == 0 && point != 0)) _bad();
    points.add(point);
    last = point;
  }
  final c = _Cursor(Uint8List.sublistView(block, 0, end));
  var previous = Uint8List(0);
  var keyBytes = 0;
  final result = <MapEntry<Uint8List, Uint8List>>[];
  while (!c.done) {
    final start = c.position;
    final shared = c.varint(), extra = c.varint(), size = c.varint();
    if (shared > previous.length || (points.remove(start) && shared != 0)) {
      _bad();
    }
    keyBytes += shared + extra;
    if (shared + extra > 65536 || keyBytes > 32 * 1024 * 1024) {
      _unsupported();
    }
    final key = Uint8List(shared + extra);
    key.setRange(0, shared, previous);
    key.setRange(shared, key.length, c.take(extra));
    result.add(MapEntry(key, c.take(size)));
    previous = key;
    if (result.length > _entryLimit) _unsupported();
  }
  if (points.any((point) => point != end)) _bad();
  return result;
}

String? _storageKey(Uint8List key) {
  final split = key.indexOf(0);
  if (split < 0 ||
      split + 1 >= key.length ||
      latin1.decode(key.sublist(0, split)) != '_app://resources') {
    return null;
  }
  return _chromiumString(Uint8List.sublistView(key, split + 1));
}

String _chromiumString(Uint8List bytes) {
  if (bytes.isEmpty) _bad();
  if (bytes[0] == 1) return latin1.decode(bytes.sublist(1));
  if (bytes[0] != 0 || bytes.length.isEven) _bad();
  final chars = <int>[];
  for (var i = 1; i < bytes.length; i += 2) {
    chars.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(chars);
}

dynamic _json(String text) {
  if (text.length > _jsonLimit) _unsupported();
  var depth = 0, quoted = false, escape = false;
  for (final n in text.codeUnits) {
    if (quoted) {
      if (escape) {
        escape = false;
      } else if (n == 92) {
        escape = true;
      } else if (n == 34) {
        quoted = false;
      }
    } else if (n == 34) {
      quoted = true;
    } else if (n == 123 || n == 91) {
      if (++depth > 80) _unsupported();
    } else if (n == 125 || n == 93) {
      depth--;
    }
  }
  return jsonDecode(text);
}

class _LimitedSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  int length = 0;
  @override
  void add(List<int> chunk) {
    length += chunk.length;
    if (length > _jsonLimit) _unsupported();
    bytes.add(chunk);
  }

  @override
  void close() {}
}

String _account(String root) {
  final bytes = _read(
      '$root${Platform.pathSeparator}LunaStorage${Platform.pathSeparator}Config',
      _jsonLimit);
  if (bytes.length < 6 || !_same(bytes.sublist(0, 4), [76, 85, 78, 65])) {
    _unsupported();
  }
  final sink = _LimitedSink();
  final decode = gzip.decoder.startChunkedConversion(sink);
  decode.add(Uint8List.sublistView(bytes, 4));
  decode.close();
  final object = _json(utf8.decode(sink.bytes.takeBytes()));
  final cached = object is Map ? object['userInfoStateCache'] : null;
  final info = cached is Map ? cached['my_info'] : null;
  final id = info is Map ? info['id'] : null;
  if (id is! String || !RegExp(r'^[0-9]{1,32}$').hasMatch(id)) {
    throw const SodaCacheFailure('soda_no_account');
  }
  return id;
}

SodaCacheState _capture(String root) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return _captureOnce(root);
    } on _Changed {
      // Concurrent compaction/rotation is an ordinary busy provider, not a
      // reason to open its database or take its writer lock.
    } on FileSystemException {
      // Retry only the bounded capture; never request or play provider content.
    } on FormatException {
      throw const SodaCacheFailure('soda_source_corrupt');
    } on RangeError {
      throw const SodaCacheFailure('soda_source_corrupt');
    }
  }
  throw const SodaCacheFailure('soda_source_busy');
}

SodaCacheState _captureOnce(String root) {
  final account = _account(root);
  final base =
      '$root${Platform.pathSeparator}Local Storage${Platform.pathSeparator}leveldb';
  final currentPath = '$base${Platform.pathSeparator}CURRENT';
  final current = _read(currentPath, 256);
  final name = ascii.decode(current).trim();
  if (!RegExp(r'^MANIFEST-[0-9]{1,20}$').hasMatch(name)) _bad();
  final manifestPath = '$base${Platform.pathSeparator}$name';
  final manifest = _read(manifestPath, 8 * 1024 * 1024);
  final version = _Version();
  for (final record in _logRecords(manifest, manifest: true)) {
    version.edit(record);
  }
  if (!version.comparatorSeen || version.log <= 0) _unsupported();
  List<String> logs() => Directory(base)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) {
        if (!RegExp(r'^[0-9]{1,20}\.log$').hasMatch(n)) return false;
        final number = int.tryParse(n.split('.').first);
        return number != null &&
            (number >= version.log || number == version.previousLog);
      }).toList()
        ..sort();
  final logNames = logs();
  if (logNames.length > 16) _unsupported();
  if (!logNames.any((n) => int.parse(n.split('.').first) == version.log)) {
    throw _Changed();
  }
  // Copy the selected live files into bounded, private memory first. Parsing
  // below never follows a live file again; it operates on these copied bytes.
  // SSTables are immutable; manifest/current/account fences detect compaction
  // or account changes while acquiring this snapshot. WALs use complete batches.
  final tables = <int, Uint8List>{};
  final wal = <String, Uint8List>{};
  var copiedBytes = current.length + manifest.length;
  for (final file in version.files.entries) {
    final number = file.key.toString().padLeft(6, '0');
    var path = '$base${Platform.pathSeparator}$number.ldb';
    if (!File(path).existsSync()) {
      path = '$base${Platform.pathSeparator}$number.sst';
    }
    final bytes = _read(path);
    copiedBytes += bytes.length;
    if (copiedBytes > 128 * 1024 * 1024) _unsupported();
    if (bytes.length != file.value.size) throw _Changed();
    tables[file.key] = bytes;
  }
  for (final name in logNames) {
    final bytes = _read('$base${Platform.pathSeparator}$name');
    copiedBytes += bytes.length;
    if (copiedBytes > 128 * 1024 * 1024) _unsupported();
    wal[name] = bytes;
  }
  if (!_same(current, _read(currentPath, 256)) ||
      !_same(manifest, _read(manifestPath, 8 * 1024 * 1024)) ||
      !_same(
          utf8.encode(logNames.join('\n')), utf8.encode(logs().join('\n')))) {
    throw _Changed();
  }
  if (account != _account(root)) {
    throw const SodaCacheFailure('soda_account_changed');
  }
  final values = <String, ({int sequence, int kind, Uint8List value})>{};
  var entriesSeen = 0;
  var decodedBytes = 0;
  Uint8List readBlock(Uint8List file, ({int offset, int size}) handle) {
    final bytes = _block(file, handle);
    decodedBytes += bytes.length;
    if (decodedBytes > 128 * 1024 * 1024) {
      _unsupported();
    }
    return bytes;
  }

  void accept(Uint8List key, int sequence, int kind, Uint8List value) {
    if (++entriesSeen > _entryLimit ||
        sequence > _sequenceLimit ||
        (kind != 0 && kind != 1)) {
      _unsupported();
    }
    final name = _storageKey(key);
    if (name == null ||
        (name != 'useRequestCache:playlists:$account' &&
            !RegExp(r'^useRequestCache:playlist_detail:[0-9]{1,32}$')
                .hasMatch(name))) {
      return;
    }
    if (value.length > _jsonLimit) _unsupported();
    final old = values[name];
    if (old == null || sequence > old.sequence) {
      values[name] = (sequence: sequence, kind: kind, value: value);
    } else if (sequence == old.sequence &&
        (kind != old.kind || !_same(value, old.value))) {
      _bad();
    }
  }

  for (final file in version.files.entries) {
    final bytes = tables[file.key]!;
    if (bytes.length != file.value.size || bytes.length < 48) throw _Changed();
    if (!_same(bytes.sublist(bytes.length - 8),
        [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb])) {
      _bad();
    }
    final footer = _Cursor(
        Uint8List.sublistView(bytes, bytes.length - 48, bytes.length - 8));
    _handle(footer);
    final index = _handle(footer);
    for (final entry in _entries(readBlock(bytes, index))) {
      final h = _Cursor(entry.value);
      final location = _handle(h);
      if (!h.done) _bad();
      for (final item in _entries(readBlock(bytes, location))) {
        if (item.key.length < 8) _bad();
        final tag =
            _Cursor(Uint8List.sublistView(item.key, item.key.length - 8))
                .uint64();
        accept(Uint8List.sublistView(item.key, 0, item.key.length - 8),
            tag >> 8, tag & 255, item.value);
      }
    }
  }
  for (final name in logNames) {
    final bytes = wal[name]!;
    for (final record in _logRecords(bytes, manifest: false)) {
      final c = _Cursor(record);
      final sequence = c.uint64(), count = c.uint32();
      if (count > _entryLimit || sequence + count > _sequenceLimit) {
        _unsupported();
      }
      for (var i = 0; i < count; i++) {
        final kind = c.byte(), key = c.slice();
        if (kind != 0 && kind != 1) _unsupported();
        accept(key, sequence + i, kind, kind == 1 ? c.slice() : Uint8List(0));
      }
      if (!c.done) _bad();
    }
  }
  if (!_same(current, _read(currentPath, 256)) ||
      !_same(manifest, _read(manifestPath, 8 * 1024 * 1024)) ||
      !_same(
          utf8.encode(logNames.join('\n')), utf8.encode(logs().join('\n')))) {
    throw _Changed();
  }
  if (account != _account(root)) {
    throw const SodaCacheFailure('soda_account_changed');
  }
  Map<String, dynamic>? decoded(String key) {
    final entry = values[key];
    if (entry == null || entry.kind == 0) return null;
    final object = _json(_chromiumString(entry.value));
    if (object is! Map<String, dynamic>) _bad();
    return object;
  }

  final catalog = decoded('useRequestCache:playlists:$account');
  if (catalog == null) throw const SodaCacheFailure('soda_unavailable');
  final data = catalog['data'];
  if (data is! Map ||
      data['playlists'] is! List ||
      (data['playlists'] as List).length > 500) {
    _bad();
  }
  final details = <String, Map<String, dynamic>>{};
  for (final playlist in data['playlists'] as List) {
    if (playlist is! Map || playlist['id'] is! String) _bad();
    final id = playlist['id'] as String;
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id)) _bad();
    final detail = decoded('useRequestCache:playlist_detail:$id');
    if (detail != null) details[id] = detail;
  }
  final revision = sha256
      .convert(utf8.encode(jsonEncode([account, catalog, details])))
      .toString();
  return SodaCacheState(
      accountId: account,
      revision: revision,
      catalog: catalog,
      details: details);
}
