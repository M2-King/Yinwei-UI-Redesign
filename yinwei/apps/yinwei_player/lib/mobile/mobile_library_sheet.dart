import 'package:flutter/material.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Imported files on this device. Playback stays in the existing engine path:
/// choosing a file only hands its library path to [onPlay].
class MobileLibrarySheet extends StatefulWidget {
  const MobileLibrarySheet({
    super.key,
    required this.media,
    required this.onPlay,
    this.onImport,
  });

  final MediaFileAcquisition media;
  final ValueChanged<String> onPlay;
  final VoidCallback? onImport;

  @override
  State<MobileLibrarySheet> createState() => _MobileLibrarySheetState();
}

class _MobileLibrarySheetState extends State<MobileLibrarySheet> {
  late Future<List<MediaLibraryEntry>> _entries = widget.media.library();

  Future<void> _remove(MediaLibraryEntry entry) async {
    await widget.media.remove(entry.path);
    if (!mounted) return;
    final next = widget.media.library();
    setState(() {
      _entries = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
        child: Column(
          key: const Key('ios-library-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Library', style: theme.textTheme.titleMedium),
                ),
                if (widget.onImport != null)
                  TextButton.icon(
                    key: const Key('ios-library-import'),
                    onPressed: widget.onImport,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Import'),
                  ),
              ],
            ),
            Text(
              'Files you open or share to Yinwei play here with spatial '
              'audio on this iPad. Streaming-app downloads are protected '
              'and cannot be imported.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: YinweiColors.textSecondary),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<MediaLibraryEntry>>(
                future: _entries,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final entries = snapshot.data ?? const [];
                  if (entries.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No files yet. Tap Import, or share an audio file '
                        'to Yinwei from the Files app.',
                        key: const Key('ios-library-empty'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        key: Key('ios-library-item-$index'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.music_note_rounded),
                        title: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_size(entry.bytes)),
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onPlay(entry.path);
                        },
                        trailing: IconButton(
                          key: Key('ios-library-remove-$index'),
                          tooltip: 'Remove from library',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _remove(entry),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).ceil()} KB';
  }
}
