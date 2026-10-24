// The native process list must give the same answers WMI gave, much faster.
// Windows only; runs against the real 汽水 when it is running (owner's laptop).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/remote_music_app.dart';

typedef _Row = ({int pid, int parent, String path, String cmd});

Future<List<_Row>> _wmiSoda() async {
  final r = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "@(Get-CimInstance Win32_Process -Filter \"Name='SodaMusic.exe'\" | "
        "ForEach-Object { @{ pid=[int]\$_.ProcessId; parent=[int]\$_.ParentProcessId; "
        "path=[string]\$_.ExecutablePath; cmd=[string]\$_.CommandLine } }) | "
        'ConvertTo-Json -Compress',
  ]);
  final text = '${r.stdout}'.trim();
  if (text.isEmpty) return const [];
  final data = jsonDecode(text);
  return [
    for (final m in (data is List ? data : [data]).cast<Map>())
      (
        pid: m['pid'] as int,
        parent: m['parent'] as int,
        path: m['path'] as String,
        cmd: m['cmd'] as String
      )
  ];
}

void main() {
  late List<_Row> soda;
  late int main;
  setUpAll(() async {
    soda = await _wmiSoda();
    final pids = soda.map((r) => r.pid).toSet();
    final mains = soda
        .where((r) => !r.cmd.contains('--type=') && !pids.contains(r.parent));
    main = mains.isEmpty ? 0 : mains.first.pid;
  });
  bool skip() => !Platform.isWindows;

  test('media reader finds 汽水 main process like WMI, fast', () async {
    if (main == 0) return markTestSkipped('汽水 is not running');
    final clock = Stopwatch()..start();
    final hit = await SystemMediaService().resolveLoopbackPid('汽水音乐');
    // ignore: avoid_print
    print('NATIVE_PROC resolveLoopbackPid ${clock.elapsedMilliseconds} ms');
    expect(hit?.pid, main);
    expect(hit?.name, 'SodaMusic');
    // One WMI query alone took ~21 s on the owner's laptop; a new PowerShell ~5 s.
    expect(clock.elapsedMilliseconds, lessThan(20000));
  }, skip: skip(), timeout: const Timeout(Duration(minutes: 3)));

  test('audio route lists every 汽水 process like WMI', () async {
    if (main == 0) return markTestSkipped('汽水 is not running');
    final dir = await Directory.systemTemp.createTemp('yw-route-');
    try {
      final script = File('${dir.path}${Platform.pathSeparator}route.ps1');
      await writeRouteScript(script);
      final clock = Stopwatch()..start();
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        'processes',
        '$main'
      ]);
      // ignore: avoid_print
      print('NATIVE_PROC route processes ${clock.elapsedMilliseconds} ms');
      final listed = LineSplitter.split('${r.stdout}')
          .where((l) => l.startsWith('PROCESS '))
          .map((l) => (jsonDecode(l.substring(8)) as Map)['pid'] as int)
          .toSet();
      expect(listed, soda.map((r) => r.pid).toSet());
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: skip(), timeout: const Timeout(Duration(minutes: 3)));

  test('music app finds 汽水 main process and path like WMI', () async {
    if (main == 0) return markTestSkipped('汽水 is not running');
    final clock = Stopwatch()..start();
    final running = await RemoteMusicApp.listRunningForTest();
    final path = await RemoteMusicApp.processPathForTest(main);
    // ignore: avoid_print
    print('NATIVE_PROC music app ${clock.elapsedMilliseconds} ms');
    final wmiMains =
        soda.where((r) => !r.cmd.contains('--type=')).map((r) => r.pid).toSet();
    expect(
        running
            .where((a) => a.process == 'SodaMusic')
            .map((a) => a.pid)
            .toSet(),
        wmiMains);
    expect(path, soda.firstWhere((r) => r.pid == main).path);
  }, skip: skip(), timeout: const Timeout(Duration(minutes: 3)));
}
