import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The iPad's cover cache (docs/IMPLEMENTATION_LISTEN_ROOM_COVERS.md, C2):
/// the 64 most recent covers in memory as page-ready data URLs, and up to
/// [maxDiskBytes] on disk in the app's caches folder (iOS may clear it; a
/// miss just asks the laptop again). Files are named by a hash of the
/// selection, never by song IDs or titles.
class ListenCoverCache {
  ListenCoverCache(
      {Directory? directory,
      Future<Directory?> Function()? directoryProvider,
      this.maxDiskBytes = 50 * 1024 * 1024})
      : _directory = directory,
        _provider = directoryProvider;

  /// Found on first use, so creating the cache never delays the room.
  Directory? _directory;
  Future<Directory?> Function()? _provider;
  Future<Directory?> _dir() async {
    final provider = _provider;
    if (provider != null) {
      _provider = null;
      try {
        _directory = await provider();
      } catch (_) {
        _directory = null; // memory only
      }
    }
    return _directory;
  }
  final int maxDiskBytes;
  static const memoryCount = 64;
  final _memory = <String, String>{}; // insertion-ordered: oldest first

  /// A stable file key for one selection (not the page's per-run key).
  static String keyOf(String source, Map<String, String> selection) {
    final parts = selection.keys.toList()..sort();
    return sha256
        .convert(utf8.encode(
            jsonEncode([source, for (final k in parts) [k, selection[k]]])))
        .toString()
        .substring(0, 40);
  }

  String? _hot(String key) {
    final value = _memory.remove(key);
    if (value != null) _memory[key] = value;
    return value;
  }

  void _keep(String key, String dataUrl) {
    _memory.remove(key);
    _memory[key] = dataUrl;
    while (_memory.length > memoryCount) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<File?> _file(String key) async {
    final dir = await _dir();
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}$key.cover');
  }

  Future<String?> get(String key) async {
    final hot = _hot(key);
    if (hot != null) return hot;
    final file = await _file(key);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (!text.startsWith('data:image/')) return null;
      await file.setLastModified(DateTime.now());
      _keep(key, text);
      return text;
    } catch (_) {
      return null;
    }
  }

  Future<void> put(String key, String dataUrl) async {
    _keep(key, dataUrl);
    final file = await _file(key);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(dataUrl, flush: true);
      await _evict(file.parent);
    } catch (_) {}
  }

  Future<void> _evict(Directory directory) async {
    final files = <({File file, int size, DateTime used})>[];
    var total = 0;
    await for (final e in directory.list()) {
      if (e is! File || !e.path.endsWith('.cover')) continue;
      final stat = await e.stat();
      files.add((file: e, size: stat.size, used: stat.modified));
      total += stat.size;
    }
    if (total <= maxDiskBytes) return;
    files.sort((a, b) => a.used.compareTo(b.used));
    for (final f in files) {
      if (total <= maxDiskBytes) break;
      try {
        await f.file.delete();
        total -= f.size;
      } catch (_) {}
    }
  }
}
