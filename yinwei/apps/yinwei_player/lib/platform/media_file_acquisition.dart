import 'dart:io';

import 'package:flutter/foundation.dart';
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
            () async => Directory(
                  '${Directory.systemTemp.path}${Platform.pathSeparator}yinwei-media',
                ),
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
  }) : _copy = copy ?? _copyFile;

  final Future<Directory> Function() resolveDirectory;
  final Future<void> Function(String from, String to) _copy;

  static Future<void> _copyFile(String from, String to) async {
    await File(from).copy(to);
  }

  @override
  Future<String> prepareReadablePath(String selectedPath) async {
    final dir = await resolveDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final name = selectedPath.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty) return selectedPath;
    final dest = '${dir.path}${Platform.pathSeparator}$name';
    if (_samePath(selectedPath, dest)) return dest;
    await _copy(selectedPath, dest);
    return dest;
  }

  static bool _samePath(String a, String b) {
    return File(a).absolute.path.toLowerCase() ==
        File(b).absolute.path.toLowerCase();
  }
}
