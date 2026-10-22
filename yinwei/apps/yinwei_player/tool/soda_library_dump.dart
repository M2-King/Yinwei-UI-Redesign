// Preview-only metadata CLI. No Flutter startup, playback, credentials or disk
// history. Keep one --stdio process for a session: library handles are opaque
// and session scoped. The existing cache reader snapshots bytes in memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/remote/soda_cache_reader.dart';
import 'package:yinwei_player/remote/soda_library.dart';

/// The production adapter persists immutable history. In this CLI those writes
/// are sunk into RAM instead; SodaLibrary itself retains the session snapshots.
/// No existing Yinwei history/account directory is opened or restored.
class PreviewLibrary {
  PreviewLibrary({SodaCacheReader? reader}) {
    library =
        SodaLibrary(reader: reader, storageDirectory: _MemoryDirectory(_root));
  }
  static final _root = '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'yinwei-preview-memory-only';
  late final SodaLibrary library;
  Future<T> memory<T>(Future<T> Function() action) =>
      IOOverrides.runWithIOOverrides(action, _MemoryIO(_root));

  Future<Map<String, dynamic>> browse(Map<String, dynamic> request) async {
    if (request.keys.any((k) =>
            !const {'list', 'snapshot', 'offset', 'query'}.contains(k)) ||
        request.entries.any((e) => e.key == 'offset'
            ? e.value is! int || (e.value as int) < 0
            : e.value is! String || (e.value as String).length > 160)) {
      return {'error': 'soda_invalid_selection'};
    }
    try {
      return await memory(() => library.browse(request));
    } on SodaLibraryFailure catch (e) {
      return {'error': e.code};
    } catch (_) {
      return {'error': 'soda_unavailable'};
    }
  }
}

final class _MemoryIO extends IOOverrides {
  _MemoryIO(this.root);
  final String root;
  bool _inside(String path) =>
      path == root || path.startsWith('$root${Platform.pathSeparator}');
  @override
  Directory createDirectory(String path) =>
      _inside(path) ? _MemoryDirectory(path) : super.createDirectory(path);
  @override
  File createFile(String path) =>
      _inside(path) ? _MemoryFile(path) : throw StateError('unexpected_file');
}

// Deliberately implement only the storage calls SodaLibrary needs. Any new
// operation fails closed rather than touching a real file. No snapshot bytes
// are duplicated here: the library already holds them with a 64 MiB limit.
class _MemoryDirectory implements Directory {
  _MemoryDirectory(this.path);
  @override
  final String path;
  @override
  Future<bool> exists() async => false;
  @override
  bool existsSync() => false;
  @override
  Future<Directory> create({bool recursive = false}) async => this;
  @override
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('memory_history');
}

class _MemoryFile implements File {
  _MemoryFile(this.path);
  @override
  final String path;
  @override
  Future<bool> exists() async => false;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    if (mode != FileMode.writeOnly) throw UnsupportedError('memory_history');
    return _MemoryOutput();
  }

  @override
  Future<File> rename(String newPath) async => _MemoryFile(newPath);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('memory_history');
}

class _MemoryOutput implements RandomAccessFile {
  @override
  Future<RandomAccessFile> writeString(String value,
          {Encoding encoding = utf8}) async =>
      this;
  @override
  Future<RandomAccessFile> flush() async => this;
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('memory_history');
}

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single != '--stdio') {
    stderr.writeln(
        'Usage: soda_library_dump.dart --stdio (JSON requests on stdin)');
    exitCode = 64;
    return;
  }
  final preview = PreviewLibrary();
  var requests = 0;
  // Bounded lines, not LineSplitter (which could buffer an unbounded input).
  final pending = <int>[];
  await for (final chunk in stdin) {
    for (final byte in chunk) {
      if (byte != 10) {
        if (pending.length >= 4096) {
          exitCode = 65;
          return;
        }
        pending.add(byte);
        continue;
      }
      if (++requests > 1000) return;
      Map<String, dynamic> result;
      try {
        final value = jsonDecode(utf8.decode(pending));
        result = value is Map<String, dynamic>
            ? await preview.browse(value).timeout(const Duration(seconds: 9))
            : {'error': 'soda_invalid_selection'};
      } catch (_) {
        result = {'error': 'soda_unavailable'};
      }
      pending.clear();
      var wire = jsonEncode(result);
      if (utf8.encode(wire).length > 2 * 1024 * 1024) {
        wire = '{"error":"soda_response_too_large"}';
      }
      stdout.writeln(wire);
      await stdout.flush();
    }
  }
}
