import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/remote_music_app.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

const soda = r'C:\Users\me\AppData\Local\SodaMusic\SodaMusic.exe';

SystemMediaState media({
  String title = '晴天',
  String source = '汽水音乐',
  int pid = 4242,
  String process = 'SodaMusic',
}) =>
    SystemMediaState(
        active: true,
        title: title,
        sourceApp: source,
        pid: pid,
        processName: process);

void main() {
  late Directory dir;
  late File file;
  late Map<int, String> paths;
  late List<int> asked;
  late List<String> launched;
  late Set<String> onDisk;
  Object? launchError;

  RemoteMusicApp app({Duration timeout = const Duration(milliseconds: 200)}) =>
      RemoteMusicApp(
        file: file,
        executablePath: (pid) async {
          asked.add(pid);
          return paths[pid];
        },
        launch: (path) async {
          if (launchError != null) throw launchError!;
          launched.add(path);
        },
        exists: onDisk.contains,
        readyTimeout: timeout,
        poll: const Duration(milliseconds: 10),
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yinwei_music_app');
    file = File('${dir.path}${Platform.pathSeparator}remote_music_app.json');
    paths = {4242: soda};
    asked = [];
    launched = [];
    onDisk = {soda};
    launchError = null;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('only allow-listed music players are remembered', () {
    expect(RemoteMusicApp.isMusicProcess('SodaMusic'), isTrue);
    expect(RemoteMusicApp.isMusicProcess('Spotify'), isTrue);
    expect(RemoteMusicApp.isMusicProcess('cloudmusic'), isTrue);
    expect(RemoteMusicApp.isMusicProcess('msedge'), isFalse);
    expect(RemoteMusicApp.isMusicProcess('chrome'), isFalse);
    expect(RemoteMusicApp.isMusicProcess('yinwei_player'), isFalse);
    expect(RemoteMusicApp.isMusicProcess('powershell'), isFalse);
    expect(RemoteMusicApp.isMusicProcess(''), isFalse);
  });

  test('only a desktop .exe by absolute path can be opened', () {
    expect(RemoteMusicApp.launchable(soda), isTrue);
    expect(RemoteMusicApp.launchable(r'SodaMusic.exe'), isFalse);
    expect(RemoteMusicApp.launchable(r'C:\Music\Soda.lnk'), isFalse);
    expect(
        RemoteMusicApp.launchable(
            r'C:\Program Files\WindowsApps\Spotify_1.2\Spotify.exe'),
        isFalse);
  });

  test('names: display name, .exe stripped, Store id → process', () {
    expect(RemoteMusicApp.displayName(media()), '汽水音乐');
    expect(
        RemoteMusicApp.displayName(
            media(source: 'Spotify.exe', process: 'Spotify')),
        'Spotify');
    expect(
        RemoteMusicApp.displayName(media(
            source: 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify',
            process: 'Spotify')),
        'Spotify');
  });

  test('the opened app gets no Yinwei settings', () {
    final env = RemoteMusicApp.launchEnvironment({
      'PATH': r'C:\Windows',
      'APPDATA': r'C:\Users\me\AppData\Roaming',
      'YINWEI_REMOTE_ENABLED': '1',
      'yinwei_remote_account_file': 'x',
      'FLUTTER_TEST': 'true',
    });
    expect(env.keys, unorderedEquals(['PATH', 'APPDATA']));
  });

  test('remembers a playing music app, saves it and reloads it', () async {
    final first = app();
    await first.observe(media());
    expect(first.name, '汽水音乐');
    expect(jsonDecode(file.readAsStringSync()),
        {'path': soda, 'name': '汽水音乐'});
    await first.observe(media());
    expect(asked, [4242], reason: 'the same process is looked up once');

    final again = app();
    expect(again.name, isNull);
    await again.load();
    expect(again.name, '汽水音乐');
  });

  test('ignores no song, browsers, Store apps and unknown paths', () async {
    final a = app();
    await a.observe(media(title: ''));
    await a.observe(media(pid: 7, process: 'msedge', source: 'msedge.exe'));
    paths[8] = r'C:\Program Files\WindowsApps\Spotify\Spotify.exe';
    await a.observe(media(pid: 8, process: 'Spotify', source: 'Spotify.exe'));
    await a.observe(media(pid: 9));
    expect(a.name, isNull);
    expect(file.existsSync(), isFalse);
    expect(asked, [8, 9], reason: 'no lookup for a browser or no song');
  });

  test('a remembered app whose .exe is gone is not offered', () async {
    file.writeAsStringSync(jsonEncode({'path': soda, 'name': '汽水音乐'}));
    onDisk.clear();
    final a = app();
    await a.load();
    expect(a.name, isNull);
  });

  test('open: nothing remembered is no_music_app; nothing launched',
      () async {
    await expectLater(app().open(() => false),
        throwsA(isA<RemoteFailure>().having((f) => f.code, 'code', 'no_music_app')));
    expect(launched, isEmpty);
  });

  test('open: launches the remembered app and waits for its song', () async {
    final a = app(timeout: const Duration(seconds: 2));
    await a.observe(media());
    var polls = 0;
    await a.open(() => ++polls > 3);
    expect(launched, [soda]);
  });

  test('open: no song in time is music_app_no_song', () async {
    final a = app();
    await a.observe(media());
    await expectLater(
        a.open(() => false),
        throwsA(isA<RemoteFailure>()
            .having((f) => f.code, 'code', 'music_app_no_song')));
  });

  test('open: a launch error is music_app_open_failed', () async {
    final a = app();
    await a.observe(media());
    launchError = const FileSystemException('denied');
    await expectLater(
        a.open(() => true),
        throwsA(isA<RemoteFailure>()
            .having((f) => f.code, 'code', 'music_app_open_failed')));
  });

  test('open: an .exe removed since is forgotten', () async {
    final a = app();
    await a.observe(media());
    onDisk.clear();
    await expectLater(
        a.open(() => true),
        throwsA(isA<RemoteFailure>()
            .having((f) => f.code, 'code', 'no_music_app')));
    expect(a.name, isNull);
    expect(launched, isEmpty);
  });
}
