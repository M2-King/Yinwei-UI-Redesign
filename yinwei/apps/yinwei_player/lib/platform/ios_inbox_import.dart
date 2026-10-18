import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';

/// Moves files shared to Yinwei into the import library.
///
/// Info.plist declares audio document types with
/// `LSSupportsOpeningDocumentsInPlace = NO`, so "Open in Yinwei" and the share
/// sheet make iOS copy the file into `Documents/Inbox` before Yinwei is
/// foregrounded. No native URL handler is involved: the app scans the inbox on
/// launch and resume, copies each file into the bounded cache and deletes the
/// inbox copy.
class IosInboxImport {
  IosInboxImport({
    required this.media,
    Future<Directory> Function()? resolveInbox,
  }) : _resolveInbox = resolveInbox ?? _defaultInbox;

  final MediaFileAcquisition media;
  final Future<Directory> Function() _resolveInbox;

  static Future<Directory> _defaultInbox() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}${Platform.pathSeparator}Inbox');
  }

  /// Imports every waiting file, oldest first. Returns the library paths.
  Future<List<String>> collect() async {
    final inbox = await _resolveInbox();
    if (!inbox.existsSync()) return const [];
    final waiting = inbox
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    final imported = <String>[];
    for (final file in waiting) {
      try {
        imported.add(await media.prepareReadablePath(file.path));
      } finally {
        try {
          await file.delete();
        } on FileSystemException {
          // Left for the next scan; never blocks the remaining files.
        }
      }
    }
    return imported;
  }
}
