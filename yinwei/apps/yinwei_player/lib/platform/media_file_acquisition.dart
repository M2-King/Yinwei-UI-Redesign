import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

/// Turns a user-selected media URL/path into an engine-readable file path.
///
/// Does not open the engine. [EngineController.openPath] stays unchanged.
abstract class MediaFileAcquisition {
  const MediaFileAcquisition();

  Future<String> prepareReadablePath(String selectedPath);

  factory MediaFileAcquisition.create({
    required PlatformCapabilities capabilities,
    bool? isIOS,
    Future<Directory> Function()? resolveOwnedDirectory,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    final android = !kIsWeb && Platform.isAndroid;
    if ((ios || android) && capabilities.mobileFileImport) {
      return CopyingMediaFileAcquisition(
        resolveDirectory: resolveOwnedDirectory ??
            () async {
              final support = await getApplicationSupportDirectory();
              return Directory(
                '${support.path}${Platform.pathSeparator}media-cache',
              );
            },
      );
    }
    return const PassthroughMediaFileAcquisition();
  }
}

class PassthroughMediaFileAcquisition implements MediaFileAcquisition {
  const PassthroughMediaFileAcquisition();

  @override
  Future<String> prepareReadablePath(String selectedPath) async => selectedPath;
}

/// Copies a selected file into an app-owned directory before engine open.
///
/// Intended for iOS security-scoped / inbox URLs. The copy is the contract;
/// UIKit document picking stays outside this type.
class CopyingMediaFileAcquisition implements MediaFileAcquisition {
  CopyingMediaFileAcquisition({
    required this.resolveDirectory,
    Future<void> Function(String from, String to)? copy,
    DateTime Function()? now,
    this.maxFiles = 8,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  })  : assert(maxFiles > 0),
        assert(maxTotalBytes > 0),
        _copy = copy ?? _copyFile,
        _now = now ?? DateTime.now;

  final Future<Directory> Function() resolveDirectory;
  final Future<void> Function(String from, String to) _copy;
  final DateTime Function() _now;
  final int maxFiles;
  final int maxTotalBytes;
  int _sequence = 0;

  static Future<void> _copyFile(String from, String to) async {
    await File(from).copy(to);
  }

  @override
  Future<String> prepareReadablePath(String selectedPath) async {
    final dir = await resolveDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final name = selectedPath.split(RegExp(r'[\\/]')).last.trim();
    if (name.isEmpty) return selectedPath;

    final source = File(selectedPath);
    if (_isInside(source, dir)) return source.absolute.path;

    final safe = _safeName(name);
    final dot = safe.lastIndexOf('.');
    final rawStem = dot > 0 ? safe.substring(0, dot) : safe;
    final stem = rawStem.length > 80 ? rawStem.substring(0, 80) : rawStem;
    final extension = dot > 0 ? safe.substring(dot) : '';
    final stamp = _now().toUtc().microsecondsSinceEpoch;
    final serial = _sequence++;
    final dest = '${dir.path}${Platform.pathSeparator}'
        '$stem-$stamp-$serial$extension';
    final partial = '$dest.partial';
    try {
      await _copy(selectedPath, partial);
      await File(partial).rename(dest);
    } finally {
      final leftover = File(partial);
      if (leftover.existsSync()) {
        await leftover.delete();
      }
    }
    final copied = File(dest);
    if (copied.lengthSync() > maxTotalBytes) {
      await copied.delete();
      throw FileSystemException(
        'Selected media exceeds the Yinwei import cache limit.',
        selectedPath,
      );
    }
    await _prune(dir, keepPath: dest);
    return dest;
  }

  static bool _isInside(File file, Directory directory) {
    final source = file.absolute.path.toLowerCase();
    final root = directory.absolute.path.toLowerCase();
    return source == root ||
        source.startsWith('$root${Platform.pathSeparator}');
  }

  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'yinwei-media' : cleaned;
  }

  Future<void> _prune(Directory directory, {required String keepPath}) async {
    final files = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => !file.path.endsWith('.partial'))
        .toList();
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));

    var bytes = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
    var count = files.length;
    for (final file in files) {
      if (count <= maxFiles && bytes <= maxTotalBytes) break;
      if (file.absolute.path.toLowerCase() ==
          File(keepPath).absolute.path.toLowerCase()) {
        continue;
      }
      final length = file.lengthSync();
      await file.delete();
      count--;
      bytes -= length;
    }
  }
}
