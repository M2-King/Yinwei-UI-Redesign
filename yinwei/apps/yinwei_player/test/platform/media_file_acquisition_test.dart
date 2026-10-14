import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  test('Windows path behavior is preserved by passthrough acquisition',
      () async {
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
      now: () => DateTime.utc(2026, 10, 13),
    );
    final out = await acquisition.prepareReadablePath(src.path);
    expect(out.startsWith(ownedDir.path), isTrue);
    expect(out.endsWith('.wav'), isTrue);
    expect(out, contains('clip-'));
    expect(out, isNot(src.path));
    expect(File(out).readAsBytesSync(), [1, 2, 3, 4]);
  });

  test('repeated names are collision-safe and the cache stays bounded',
      () async {
    final srcDir = await Directory.systemTemp.createTemp('yinwei-src-');
    final ownedDir = await Directory.systemTemp.createTemp('yinwei-owned-');
    addTearDown(() async {
      if (srcDir.existsSync()) await srcDir.delete(recursive: true);
      if (ownedDir.existsSync()) await ownedDir.delete(recursive: true);
    });
    final source = File('${srcDir.path}${Platform.pathSeparator}same name.wav');
    await source.writeAsBytes(const [1, 2, 3, 4]);
    var tick = 0;
    final acquisition = CopyingMediaFileAcquisition(
      resolveDirectory: () async => ownedDir,
      now: () => DateTime.fromMicrosecondsSinceEpoch(++tick, isUtc: true),
      maxFiles: 2,
      maxTotalBytes: 1024,
    );

    final first = await acquisition.prepareReadablePath(source.path);
    final second = await acquisition.prepareReadablePath(source.path);
    final third = await acquisition.prepareReadablePath(source.path);

    expect({first, second, third}.length, 3);
    expect(File(first).existsSync(), isFalse);
    expect(File(second).existsSync(), isTrue);
    expect(File(third).existsSync(), isTrue);
    expect(ownedDir.listSync().whereType<File>().length, 2);
    expect(
        ownedDir.listSync().any((e) => e.path.endsWith('.partial')), isFalse);
  });

  test('a path already inside the owned cache is reused', () async {
    final ownedDir = await Directory.systemTemp.createTemp('yinwei-owned-');
    addTearDown(() async {
      if (ownedDir.existsSync()) await ownedDir.delete(recursive: true);
    });
    final existing =
        File('${ownedDir.path}${Platform.pathSeparator}existing.wav');
    await existing.writeAsBytes(const [5, 6]);
    final acquisition = CopyingMediaFileAcquisition(
      resolveDirectory: () async => ownedDir,
    );

    expect(await acquisition.prepareReadablePath(existing.path),
        existing.absolute.path);
    expect(ownedDir.listSync().whereType<File>().length, 1);
  });

  test('an import larger than the cache limit is rejected and removed',
      () async {
    final srcDir = await Directory.systemTemp.createTemp('yinwei-src-');
    final ownedDir = await Directory.systemTemp.createTemp('yinwei-owned-');
    addTearDown(() async {
      if (srcDir.existsSync()) await srcDir.delete(recursive: true);
      if (ownedDir.existsSync()) await ownedDir.delete(recursive: true);
    });
    final source = File('${srcDir.path}${Platform.pathSeparator}large.wav');
    await source.writeAsBytes(const [1, 2, 3, 4]);
    final acquisition = CopyingMediaFileAcquisition(
      resolveDirectory: () async => ownedDir,
      maxTotalBytes: 3,
    );

    await expectLater(
      acquisition.prepareReadablePath(source.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(ownedDir.listSync(), isEmpty);
  });

  test('copy vs passthrough follows injected isIOS, not the CI host', () {
    expect(
      MediaFileAcquisition.create(
        capabilities: PlatformCapabilities.ios,
        isIOS: false,
      ),
      isA<PassthroughMediaFileAcquisition>(),
    );
    expect(
      MediaFileAcquisition.create(
        capabilities: PlatformCapabilities.ios,
        isIOS: true,
      ),
      isA<CopyingMediaFileAcquisition>(),
    );
    expect(
      MediaFileAcquisition.create(
        capabilities: PlatformCapabilities.windows,
        isIOS: true,
      ),
      isA<PassthroughMediaFileAcquisition>(),
    );
  });
}
