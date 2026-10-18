import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/mobile_library_sheet.dart';
import 'package:yinwei_player/mobile/mobile_transport.dart';
import 'package:yinwei_player/platform/ios_inbox_import.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

void main() {
  late Directory srcDir, ownedDir, inboxDir;
  late CopyingMediaFileAcquisition media;
  var tick = 0;

  setUp(() async {
    srcDir = await Directory.systemTemp.createTemp('yinwei-src-');
    ownedDir = await Directory.systemTemp.createTemp('yinwei-owned-');
    inboxDir = await Directory.systemTemp.createTemp('yinwei-inbox-');
    media = CopyingMediaFileAcquisition(
      resolveDirectory: () async => ownedDir,
      now: () => DateTime.utc(2026, 10, 18).add(Duration(seconds: tick++)),
    );
  });

  tearDown(() async {
    for (final dir in [srcDir, ownedDir, inboxDir]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  Future<String> source(String name,
      [List<int> bytes = const [1, 2, 3]]) async {
    final file = File('${srcDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test('library lists imports newest first under their original names',
      () async {
    final first = await media.prepareReadablePath(await source('Song A.flac'));
    File(first).setLastModifiedSync(DateTime(2026, 1, 1));
    await media.prepareReadablePath(await source('Song B.mp3'));

    final entries = await media.library();
    expect(entries.map((e) => e.title), ['Song B.mp3', 'Song A.flac']);
    expect(entries.last.path, first);
    expect(entries.first.bytes, 3);
  });

  test('replaying a library file does not copy it again', () async {
    final path = await media.prepareReadablePath(await source('Loop.wav'));
    expect(await media.prepareReadablePath(path), path);
    expect((await media.library()).length, 1);
  });

  test('remove deletes only files inside the owned cache', () async {
    final outside = await source('Keep.wav');
    final inside = await media.prepareReadablePath(await source('Drop.wav'));

    await media.remove(outside);
    await media.remove(inside);

    expect(File(outside).existsSync(), isTrue);
    expect(File(inside).existsSync(), isFalse);
    expect(await media.library(), isEmpty);
  });

  test('passthrough acquisition has an empty library', () async {
    const media = PassthroughMediaFileAcquisition();
    expect(await media.library(), isEmpty);
    await media.remove('anything');
  });

  test('inbox files are imported oldest first and removed from the inbox',
      () async {
    final older = File('${inboxDir.path}${Platform.pathSeparator}old.mp3')
      ..writeAsBytesSync(const [1]);
    older.setLastModifiedSync(DateTime(2026, 1, 1));
    File('${inboxDir.path}${Platform.pathSeparator}new.m4a')
        .writeAsBytesSync(const [2]);

    final imported = await IosInboxImport(
      media: media,
      resolveInbox: () async => inboxDir,
    ).collect();

    expect(imported, hasLength(2));
    expect(imported.first, contains('old-'));
    expect(imported.last, contains('new-'));
    expect(inboxDir.listSync(), isEmpty);
    expect((await media.library()).map((e) => e.title),
        containsAll(['old.mp3', 'new.m4a']));
  });

  test('missing inbox imports nothing', () async {
    await inboxDir.delete();
    final imported = await IosInboxImport(
      media: media,
      resolveInbox: () async => inboxDir,
    ).collect();
    expect(imported, isEmpty);
  });

  testWidgets('library sheet plays, removes and offers import', (tester) async {
    final played = <String>[];
    var imports = 0;
    final entries = [
      MediaLibraryEntry(
          path: '/cache/a.flac',
          title: 'a.flac',
          bytes: 3 * 1024 * 1024,
          modified: DateTime(2026)),
    ];
    final fake = _FakeMedia(entries);
    await tester.pumpWidget(MaterialApp(
      theme: YinweiTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => MobileLibrarySheet(
                media: fake,
                onPlay: played.add,
                onImport: () => imports++,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('a.flac'), findsOneWidget);
    expect(find.text('3.0 MB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ios-library-import')));
    expect(imports, 1);

    await tester.tap(find.byKey(const Key('ios-library-remove-0')));
    await tester.pumpAndSettle();
    expect(fake.removed, ['/cache/a.flac']);
    expect(find.byKey(const Key('ios-library-empty')), findsOneWidget);

    fake.entries.add(entries.first);
    await tester.tap(find.byKey(const Key('ios-library-import')));
    Navigator.of(tester.element(find.byKey(const Key('ios-library-sheet'))))
        .pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ios-library-item-0')));
    await tester.pumpAndSettle();
    expect(played, ['/cache/a.flac']);
    expect(find.byKey(const Key('ios-library-sheet')), findsNothing);
  });

  testWidgets('transport shows Library only when a handler is supplied',
      (tester) async {
    final controller = EngineController();
    addTearDown(controller.dispose);
    var opened = 0;
    Widget app(VoidCallback? onLibrary) => MaterialApp(
          theme: YinweiTheme.dark(),
          home: Scaffold(
            body: MobileTransport(
              controller: controller,
              onOpen: () {},
              onLibrary: onLibrary,
            ),
          ),
        );

    await tester.pumpWidget(app(null));
    expect(find.byKey(const Key('ios-library-button')), findsNothing);
    await tester.pumpWidget(app(() => opened++));
    await tester.tap(find.byKey(const Key('ios-library-button')));
    expect(opened, 1);
  });
}

class _FakeMedia implements MediaFileAcquisition {
  _FakeMedia(List<MediaLibraryEntry> entries) : entries = [...entries];
  final List<MediaLibraryEntry> entries;
  final removed = <String>[];

  @override
  Future<List<MediaLibraryEntry>> library() async => [...entries];

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    entries.removeWhere((e) => e.path == path);
  }

  @override
  Future<String> prepareReadablePath(String selectedPath) async => selectedPath;
}
