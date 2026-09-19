import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  test('Windows path behavior is preserved by passthrough acquisition', () async {
    const path = r'C:\Users\Tim\Music\track.wav';
    final acquisition = MediaFileAcquisition.create(
      capabilities: PlatformCapabilities.windows,
    );
    expect(acquisition, isA<PassthroughMediaFileAcquisition>());
    expect(await acquisition.prepareReadablePath(path), path);
  });

  test('iOS copy strategy returns an app-owned readable path', () async {
    final srcDir = await Directory.systemTemp.createTemp('yinwei-src-');
    final ownedDir = await Directory.systemTemp.createTemp('yinwei-owned-');
    addTearDown(() async {
      if (srcDir.existsSync()) await srcDir.delete(recursive: true);
      if (ownedDir.existsSync()) await ownedDir.delete(recursive: true);
    });
    final src = File('${srcDir.path}${Platform.pathSeparator}clip.wav');
    await src.writeAsBytes(const [1, 2, 3, 4]);

    final acquisition = CopyingMediaFileAcquisition(
      resolveDirectory: () async => ownedDir,
    );
    final out = await acquisition.prepareReadablePath(src.path);
    expect(out.startsWith(ownedDir.path), isTrue);
    expect(out.endsWith('clip.wav'), isTrue);
    expect(out, isNot(src.path));
    expect(File(out).readAsBytesSync(), [1, 2, 3, 4]);
  });
}
