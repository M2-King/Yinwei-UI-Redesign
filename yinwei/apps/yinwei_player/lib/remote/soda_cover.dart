import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Real song covers (docs/IMPLEMENTATION_LISTEN_ROOM_COVERS.md).
///
/// The owner lifted "never downloads artwork" for covers only (2026-10-24).
/// This file is the only code allowed to download artwork: from 汽水's image
/// CDN, built from a validated descriptor that 汽水 itself provided in a
/// track object (`track.album.url_cover`), never from a client.

/// Where one track's cover lives on 汽水's image CDN.
class SodaCoverRef {
  const SodaCoverRef._(this.host, this.uri, this.template);
  final String host, uri, template;

  static final _host = RegExp(r'^p[0-9]{1,2}-luna\.douyinpic\.com$');
  static final _uri = RegExp(r'^tos-[a-z0-9-]{1,40}/[A-Za-z0-9_-]{8,128}$');
  static final _template = RegExp(r'^tplv-[a-z0-9]{4,32}$');

  /// From a 汽水 track's `album` object; null when anything is unexpected.
  static SodaCoverRef? fromAlbum(Object? album) {
    if (album is! Map) return null;
    final cover = album['url_cover'];
    if (cover is! Map) return null;
    final uri = cover['uri'], template = cover['template_prefix'];
    final urls = cover['urls'];
    if (uri is! String ||
        template is! String ||
        urls is! List ||
        !_uri.hasMatch(uri) ||
        !_template.hasMatch(template)) {
      return null;
    }
    for (final raw in urls) {
      if (raw is! String) continue;
      final base = Uri.tryParse(raw);
      if (base != null &&
          base.scheme == 'https' &&
          _host.hasMatch(base.host) &&
          !base.hasPort &&
          base.path == '/img/' &&
          !base.hasQuery &&
          !base.hasFragment) {
        return SodaCoverRef._(base.host, uri, template);
      }
    }
    return null;
  }

  /// The square cover at [size] px. The suffix was confirmed against the
  /// CDN on 2026-10-24 (phase C0): `-crop-center:N:N.jpg` returns a JPEG.
  Uri url(int size) =>
      Uri.parse('https://$host/img/$uri~$template-crop-center:$size:$size.jpg');
}

class SodaCoverImage {
  const SodaCoverImage(this.mime, this.bytes);
  final String mime;
  final Uint8List bytes;
}

/// Downloads, validates and caches covers on the laptop.
///
/// - HTTPS to the allow-listed host only, no redirects, 8 s, at most 512 KB.
/// - JPEG/PNG/WebP only, checked by the bytes' signature, not just the header.
/// - At most 3 downloads at once; identical requests share one download.
/// - A failed cover is not tried again for 10 minutes.
/// - Disk cache: file names are sha256(trackId|size), so no track IDs appear
///   on disk; [maxCacheBytes] with oldest-used files deleted first.
class SodaCoverStore {
  SodaCoverStore({
    required this.directory,
    HttpClient Function()? clientFactory,
    DateTime Function()? clock,
    Future<SodaCoverImage?> Function(Uri url)? download,
    this.maxCacheBytes = 100 * 1024 * 1024,
    this.size = 480,
  })  : _clientFactory = clientFactory ?? HttpClient.new,
        _clock = clock ?? DateTime.now {
    _fetch = download ?? _download;
  }

  /// Tests pass a fake; the app downloads over HTTPS.
  late final Future<SodaCoverImage?> Function(Uri url) _fetch;

  final Directory directory;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _clock;
  final int maxCacheBytes, size;

  static const maxBytes = 512 * 1024;
  static const timeout = Duration(seconds: 8);
  static const failureBackoff = Duration(minutes: 10);
  static const maxConcurrent = 3;

  final _inFlight = <String, Future<SodaCoverImage?>>{};
  final _failedAt = <String, DateTime>{};
  int _running = 0;
  final _waiting = Queue<Completer<void>>();
  int downloads = 0, hits = 0, failures = 0;

  String _key(String trackId) =>
      sha256.convert(utf8.encode('$trackId|$size')).toString();

  /// The cover for [trackId], from the cache or downloaded from [ref].
  Future<SodaCoverImage?> cover(String trackId, SodaCoverRef ref) {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(trackId)) return Future.value();
    final key = _key(trackId);
    return _inFlight[key] ??= _load(key, ref).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<SodaCoverImage?> _load(String key, SodaCoverRef ref) async {
    final cached = await _read(key);
    if (cached != null) {
      ++hits;
      return cached;
    }
    final failed = _failedAt[key];
    if (failed != null && _clock().difference(failed) < failureBackoff) {
      return null;
    }
    await _slot();
    try {
      final image = await _fetch(ref.url(size)).timeout(timeout);
      if (image == null) {
        _fail(key);
        return null;
      }
      ++downloads;
      await _write(key, image);
      return image;
    } catch (_) {
      _fail(key);
      return null;
    } finally {
      _release();
    }
  }

  void _fail(String key) {
    ++failures;
    if (_failedAt.length >= 1000) _failedAt.remove(_failedAt.keys.first);
    _failedAt[key] = _clock();
  }

  Future<void> _slot() async {
    if (_running < maxConcurrent) {
      ++_running;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      --_running;
    }
  }

  Future<SodaCoverImage?> _download(Uri url) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'image/jpeg,image/*');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != 200 ||
          response.contentLength > maxBytes ||
          response.headers.value(HttpHeaders.contentEncodingHeader) != null) {
        await response.drain<void>();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) return null;
        bytes.add(chunk);
      }
      return imageOf(bytes.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// A JPEG, PNG or WebP by its signature; null for anything else.
  static SodaCoverImage? imageOf(Uint8List bytes) {
    bool starts(List<int> sig, [int at = 0]) =>
        bytes.length >= at + sig.length &&
        List.generate(sig.length, (i) => bytes[at + i] == sig[i]).every((b) => b);
    if (bytes.length < 64 || bytes.length > maxBytes) return null;
    if (starts([0xff, 0xd8, 0xff])) return SodaCoverImage('image/jpeg', bytes);
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return SodaCoverImage('image/png', bytes);
    }
    if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) {
      return SodaCoverImage('image/webp', bytes);
    }
    return null;
  }

  File _file(String key) =>
      File('${directory.path}${Platform.pathSeparator}$key.img');

  Future<SodaCoverImage?> _read(String key) async {
    final file = _file(key);
    try {
      if (!await file.exists()) return null;
      final image = imageOf(await file.readAsBytes());
      if (image == null) {
        await file.delete();
        return null;
      }
      // Touch for "oldest-used first" eviction.
      await file.setLastModified(_clock());
      return image;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, SodaCoverImage image) async {
    try {
      await directory.create(recursive: true);
      final file = _file(key);
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(image.bytes, flush: true);
      await temp.rename(file.path);
      await _evict();
    } catch (_) {
      // A cover that cannot be cached is still returned this time.
    }
  }

  Future<void> _evict() async {
    final files = <({File file, int size, DateTime used})>[];
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.img')) continue;
      final stat = await entity.stat();
      files.add((file: entity, size: stat.size, used: stat.modified));
      total += stat.size;
    }
    if (total <= maxCacheBytes) return;
    files.sort((a, b) => a.used.compareTo(b.used));
    for (final f in files) {
      if (total <= maxCacheBytes) break;
      try {
        await f.file.delete();
        total -= f.size;
      } catch (_) {}
    }
  }

  Map<String, Object> diagnostics() =>
      {'downloads': downloads, 'hits': hits, 'failures': failures};
}
