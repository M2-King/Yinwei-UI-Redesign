import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';

const _original =
    AudioRouteProcessIdentity(42, 'SodaMusic', '638960000000000000');
const _child = AudioRouteProcessIdentity(43, 'SodaMusic', '638960000000000001');

class _Recovery {
  _Recovery(this.file) {
    router = AppAudioRouter.forTesting(
      recoveryFile: file,
      command: run,
      log: logs.add,
    );
  }
  final File file;
  late final AppAudioRouter router;
  final processes = <int, AudioRouteProcessIdentity>{};
  final commands = <List<String>>[];
  final logs = <String>[];
  final failures = <String>{};
  Future<List<String>> Function(List<String>)? override;
  Future<void> Function(List<String>)? onApply;

  Future<List<String>> run(List<String> args) async {
    commands.add(List.of(args));
    if (override != null) return override!(args);
    if (failures.contains(args.first)) {
      throw ProcessException('test-helper', args, '', 5);
    }
    switch (args.first) {
      case 'inspect':
        final process = processes[int.parse(args[1])];
        return process == null
            ? ['MISSING']
            : ['PROCESS ${jsonEncode(process.toJson())}'];
      case 'processes':
        return processes.values
            .map((p) => 'PROCESS ${jsonEncode(p.toJson())}')
            .toList();
      case 'mute-state':
        return ['MUTED_WAS 0'];
      case 'apply':
        await onApply?.call(args);
        return processes.keys.map((pid) => 'PID $pid').toList();
      default:
        return [];
    }
  }

  Future<void> write(
          {List<AudioRouteProcessIdentity> identities = const [_original],
          List<int>? pids,
          bool unmute = true}) =>
      file.writeAsString(
          AudioRouteRecoveryState('speakers', unmute,
                  rootPid: 42,
                  routedPids: pids ?? identities.map((p) => p.pid).toList(),
                  processes: identities)
              .encode(),
          flush: true);

  Iterable<List<String>> get clears =>
      commands.where((c) => c.first == 'clear');
  Iterable<List<String>> get unmutes =>
      commands.where((c) => c.first == 'unmute');
}

void main() {
  test('recovery record preserves the routed device, mute state, and PIDs', () {
    const record = AudioRouteRecoveryState(
      r'\\?\SWD#MMDEVAPI#{speaker}',
      true,
      rootPid: 42,
      routedPids: [42, 43],
    );
    final decoded = AudioRouteRecoveryState.parse(record.encode());
    expect(decoded, isNotNull);
    expect(decoded!.speakersId, record.speakersId);
    expect(decoded.unmute, isTrue);
    expect(decoded.rootPid, 42);
    expect(decoded.routedPids, [42, 43]);
  });

  test('legacy marker and invalid records cannot be mistaken for new state',
      () {
    expect(AudioRouteRecoveryState.parse('1'), isNull);
    expect(AudioRouteRecoveryState.parse('{"speakersId":"x"}'), isNull);
    expect(
        AudioRouteRecoveryState.parse(
            '{"speakersId":"x","unmute":true,"rootPid":1,"routedPids":[1,"bad"]}'),
        isNull);
  });

  test('existing mute state is retained in recovery record', () {
    const record = AudioRouteRecoveryState(
      'speakers',
      false,
      rootPid: 7,
      routedPids: [7],
    );
    expect(AudioRouteRecoveryState.parse(record.encode())!.unmute, isFalse);
  });

  late Directory temp;
  late _Recovery recovery;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('yinwei-route-test-');
    recovery =
        _Recovery(File('${temp.path}${Platform.pathSeparator}route.dirty'));
  });
  tearDown(() async => temp.delete(recursive: true));

  test('identity roundtrip retains exact start ticks and process name',
      () async {
    await recovery.write();
    final record =
        AudioRouteRecoveryState.parse(await recovery.file.readAsString())!;
    expect(record.processes.single.matches(_original), isTrue);
    expect(record.processes.single.startTime, '638960000000000000');
  });

  test('stale-only recovery unmutes and deletes the journal without clear',
      () async {
    await recovery.write(identities: const [_original, _child]);
    await recovery.router.recoverIfDirty();
    expect(recovery.clears, isEmpty);
    expect(recovery.unmutes.single, ['unmute', 'speakers']);
    expect(await recovery.file.exists(), isFalse);
    expect(recovery.logs, ['[AudioRoute] recovered: 2 stale pids']);
  });

  test('old PID-only dead records recover without touching other apps',
      () async {
    await recovery.write(identities: const [], pids: [42, 43]);
    await recovery.router.recoverIfDirty();
    expect(recovery.clears, isEmpty);
    expect(await recovery.file.exists(), isFalse);
    expect(recovery.logs.single, '[AudioRoute] recovered: 2 stale pids');
  });

  test('mixed alive and dead clears only the matching live identity', () async {
    await recovery.write(identities: const [_original, _child]);
    recovery.processes[42] = _original;
    await recovery.router.recoverIfDirty();
    expect(recovery.clears.single.take(2), ['clear', '42']);
    expect(jsonDecode(recovery.clears.single[2]), _original.toJson());
    expect(await recovery.file.exists(), isFalse);
    expect(recovery.logs.single, '[AudioRoute] recovered: 1 stale pids');
  });

  test('PID reused by a different process is never cleared', () async {
    await recovery.write();
    recovery.processes[42] =
        const AudioRouteProcessIdentity(42, 'Editor', '638960000000000000');
    await recovery.router.recoverIfDirty();
    expect(recovery.clears, isEmpty);
    expect(await recovery.file.exists(), isFalse);
  });

  test('PID reused by the same executable with new start time is stale',
      () async {
    await recovery.write();
    recovery.processes[42] =
        const AudioRouteProcessIdentity(42, 'SodaMusic', '638960000000000009');
    await recovery.router.recoverIfDirty();
    expect(recovery.clears, isEmpty);
    expect(recovery.logs.single, '[AudioRoute] recovered: 1 stale pids');
  });

  test('old journal cannot clear a live process with no saved identity',
      () async {
    await recovery.write(identities: const [], pids: [42]);
    recovery.processes[42] = _original;
    await expectLater(recovery.router.recoverIfDirty(),
        throwsA(isA<AudioRouteRecoveryException>()));
    expect(recovery.clears, isEmpty);
    expect(recovery.unmutes, hasLength(1));
    expect(await recovery.file.exists(), isTrue);
  });

  test('legacy PID created after the record is safely recognized as reused',
      () async {
    await recovery.write(identities: const [], pids: [42]);
    await recovery.file.setLastModified(DateTime.utc(2020));
    recovery.processes[42] = _original;
    await recovery.router.recoverIfDirty();
    expect(recovery.clears, isEmpty);
    expect(await recovery.file.exists(), isFalse);
  });

  test('a failed live clear still unmutes and preserves the record', () async {
    await recovery.write();
    recovery.processes[42] = _original;
    recovery.failures.add('clear');
    await expectLater(
        recovery.router.recoverIfDirty(),
        throwsA(isA<AudioRouteRecoveryException>()
            .having((e) => e.pids, 'pids', [42])));
    expect(recovery.unmutes.single, ['unmute', 'speakers']);
    expect(await recovery.file.exists(), isTrue);
  });

  test('process exits while clear fails: recovery succeeds as stale', () async {
    await recovery.write();
    var inspections = 0;
    recovery.override = (args) async {
      if (args.first == 'inspect') {
        return ++inspections == 1
            ? ['PROCESS ${jsonEncode(_original.toJson())}']
            : ['MISSING'];
      }
      if (args.first == 'clear') throw ProcessException('test', args);
      return [];
    };
    await recovery.router.recoverIfDirty();
    expect(await recovery.file.exists(), isFalse);
    expect(recovery.logs.single, '[AudioRoute] recovered: 1 stale pids');
  });

  test('helper detects PID reuse between inspection and clear', () async {
    await recovery.write();
    recovery.override = (args) async => switch (args.first) {
          'inspect' => ['PROCESS ${jsonEncode(_original.toJson())}'],
          'clear' => ['STALE 42'],
          _ => [],
        };
    await recovery.router.recoverIfDirty();
    expect(recovery.logs.single, '[AudioRoute] recovered: 1 stale pids');
    expect(await recovery.file.exists(), isFalse);
  });

  test('recorded muted state is not unmuted', () async {
    await recovery.write(unmute: false);
    await recovery.router.recoverIfDirty();
    expect(recovery.unmutes, isEmpty);
    expect(await recovery.file.exists(), isFalse);
  });

  for (final raw in ['', 'not-json', '{', 'null', '{}']) {
    test('corrupt or empty record does not block Live: ${jsonEncode(raw)}',
        () async {
      await recovery.file.writeAsString(raw);
      expect(
          await recovery.router.recoverBeforeLive(Future.value(false)), isTrue);
      expect(await recovery.file.exists(), isFalse);
      expect(recovery.commands, isEmpty);
    });
  }

  test('damaged PID fields cannot skip a trustworthy speaker unmute', () async {
    await recovery.file.writeAsString(
        '{"speakersId":"speakers","unmute":true,"routedPids":"bad"}');
    await recovery.router.recoverIfDirty();
    expect(recovery.unmutes.single, ['unmute', 'speakers']);
  });

  test('unmute failure is retried and never poisons Live startup', () async {
    await recovery.write();
    recovery.failures.add('unmute');
    expect(
        await recovery.router.recoverBeforeLive(Future.value(false)), isTrue);
    expect(await recovery.file.exists(), isTrue);
    recovery.failures.clear();
    expect(
        await recovery.router.recoverBeforeLive(Future.value(false)), isTrue);
    expect(await recovery.file.exists(), isFalse);
  });

  test('failed startup recovery is retried after routed process exits',
      () async {
    await recovery.write();
    recovery.processes[42] = _original;
    recovery.failures.add('clear');
    final startup = recovery.router
        .recoverIfDirty()
        .then((_) => true)
        .catchError((Object _) => false);
    expect(await startup, isFalse);
    recovery.processes.clear();
    var liveStarted = false;
    if (await recovery.router.recoverBeforeLive(startup)) liveStarted = true;
    expect(liveStarted, isTrue);
    expect(recovery.router.lastRecoveryFailure, isNull);
    expect(await recovery.file.exists(), isFalse);
  });

  test(
      'failed process inspection permits Live but prevents new pin overwriting journal',
      () async {
    await recovery.write();
    recovery.failures.add('inspect');
    expect(
        await recovery.router
            .recoverBeforeLive(Future.error(StateError('startup'))),
        isTrue);
    expect(await recovery.file.exists(), isTrue);
    expect(
        await recovery.router
            .routeToSpeakers(rootPid: 42, speakersId: 'speakers'),
        isFalse);
    expect(recovery.commands.where((c) => c.first == 'apply'), isEmpty);
    expect(recovery.unmutes, hasLength(2));
  });

  test(
      'transient clear failure does not latch Live off for a surviving process',
      () async {
    await recovery.write();
    recovery.processes[42] = _original;
    recovery.failures.add('clear');
    expect(
        await recovery.router.recoverBeforeLive(Future.value(true)), isFalse);
    recovery.failures.clear();
    expect(
        await recovery.router.recoverBeforeLive(Future.value(false)), isTrue);
    expect(recovery.router.lastRecoveryFailure, isNull);
    expect(await recovery.file.exists(), isFalse);
  });

  test('a currently failing live route produces a specific start failure',
      () async {
    await recovery.write();
    recovery.processes[42] = _original;
    recovery.failures.add('clear');
    expect(
        await recovery.router.recoverBeforeLive(Future.value(true)), isFalse);
    expect(recovery.router.lastRecoveryFailure!.pids, [42]);
    expect(LaptopListenController.failureText('audio_route_restore_failed'),
        contains('running music process'));
  });

  test('routing journals identities before apply and restores them afterwards',
      () async {
    recovery.processes.addAll({42: _original, 43: _child});
    recovery.onApply = (args) async {
      final record =
          AudioRouteRecoveryState.parse(await recovery.file.readAsString())!;
      expect(record.processes.map((p) => p.pid), [42, 43]);
      expect((jsonDecode(args[3]) as List).length, 2);
    };
    expect(
        await recovery.router
            .routeToSpeakers(rootPid: 42, speakersId: 'speakers'),
        isTrue);
    await recovery.router.restore();
    expect(recovery.clears.map((c) => c[1]), ['42', '43']);
    expect(await recovery.file.exists(), isFalse);
  });

  test('concurrent recovery calls share one cleanup', () async {
    await recovery.write();
    final inspected = Completer<List<String>>();
    recovery.override = (args) async =>
        args.first == 'inspect' ? await inspected.future : <String>[];
    final first = recovery.router.recoverIfDirty();
    final second = recovery.router.recoverIfDirty();
    inspected.complete(['MISSING']);
    await Future.wait([first, second]);
    expect(recovery.logs, ['[AudioRoute] recovered: 1 stale pids']);
    expect(recovery.unmutes, hasLength(1));
  });

  test('source-follow hop keeps the original speaker unmute obligation',
      () async {
    recovery.processes[42] = _original;
    expect(
        await recovery.router
            .routeToSpeakers(rootPid: 42, speakersId: 'speakers'),
        isTrue);
    recovery.processes
      ..clear()
      ..[43] = _child;
    recovery.commands.clear();
    expect(
        await recovery.router.routeToSpeakers(
            rootPid: 43, speakersId: 'speakers', keepSpeakerMute: true),
        isTrue);
    expect(recovery.unmutes, isEmpty);
    final record =
        AudioRouteRecoveryState.parse(await recovery.file.readAsString())!;
    expect(record.unmute, isTrue);
    expect(record.processes.single.matches(_child), isTrue);
    await recovery.router.restore();
    expect(recovery.unmutes.single, ['unmute', 'speakers']);
    expect(await recovery.file.exists(), isFalse);
  });

  test('PowerShell checks identity before native clear (mock audio policy)',
      () async {
    final source = await File('lib/bridge/app_audio_route.dart').readAsString();
    final start = source.indexOf('function Get-RouteProcess(');
    final end = source.indexOf('# serve: compile', start);
    final script =
        File('${temp.path}${Platform.pathSeparator}identity-test.ps1');
    // Same encoding as production (writeRouteScript): UTF-8 with a BOM.
    await script.writeAsBytes([
      0xEF, 0xBB, 0xBF,
      ...utf8.encode(
        r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
public static class YinweiPolicy {
  public static int Calls = 0;
  public static int Pins = 0;
  public static int Result = 0;
  public static int Clear(uint pid) { Calls++; return Result; }
  public static int Set(uint pid, string device) { Pins++; return 0; }
  public static int SetMuted(string device, bool muted) { return 0; }
}
'@
''' +
            source.substring(start, end) +
            r'''
$own = Get-RouteProcess $PID
try { $identity = Route-Identity $own } finally { $own.Dispose() }
Invoke-YinweiAction 'inspect' "$PID" '' '' ''
Invoke-YinweiAction 'clear' '2147483647' '' '' ''
if ($script:YwCode -ne 0 -or [YinweiPolicy]::Calls -ne 0) { throw 'dead PID was cleared' }
$wrong = $identity | ConvertTo-Json -Compress | ConvertFrom-Json
$wrong.name = 'DifferentProcess'
Invoke-YinweiAction 'clear' "$PID" ($wrong | ConvertTo-Json -Compress) '' ''
if ([YinweiPolicy]::Calls -ne 0) { throw 'wrong name was cleared' }
$wrong.name = $identity.name
$wrong.startTime = ([long]::Parse($identity.startTime) + 1).ToString()
Invoke-YinweiAction 'clear' "$PID" ($wrong | ConvertTo-Json -Compress) '' ''
if ([YinweiPolicy]::Calls -ne 0) { throw 'reused PID was cleared' }
Invoke-YinweiAction 'clear' "$PID" ($identity | ConvertTo-Json -Compress) '' ''
if ($script:YwCode -ne 0 -or [YinweiPolicy]::Calls -ne 1) { throw 'matching PID was not cleared' }
[YinweiPolicy]::Result = -1
Invoke-YinweiAction 'clear' "$PID" ($identity | ConvertTo-Json -Compress) '' ''
if ($script:YwCode -ne 5 -or [YinweiPolicy]::Calls -ne 2) { throw 'live failure was hidden' }
[YinweiPolicy]::Result = 1
Invoke-YinweiAction 'clear' "$PID" ($identity | ConvertTo-Json -Compress) '' ''
if ($script:YwCode -ne 0) { throw 'S_FALSE should be success' }
# A multi-process journal must enumerate identities, not treat all PID values
# as one Object[]. Use the current identity twice to keep the test independent
# of other running apps while exercising the real PowerShell JSON pipeline.
$candidates = @($identity, $identity) | ConvertTo-Json -Compress
$pins = @(Invoke-YinweiAction 'apply' "$PID" 'test-only-mocked-device' $candidates '')
if ($script:YwCode -ne 0 -or [YinweiPolicy]::Pins -ne 2 -or $pins.Count -ne 2) { throw 'multi-process routing failed' }
$pins = @(Invoke-YinweiAction 'apply' "$PID" 'test-only-mocked-device' ($identity | ConvertTo-Json -Compress) '')
if ($script:YwCode -ne 0 -or [YinweiPolicy]::Pins -ne 3 -or $pins.Count -ne 1) { throw 'single-process routing failed' }
Write-Output 'IDENTITY PASS'
''')
    ], flush: true);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path
    ]).timeout(const Duration(seconds: 25));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('IDENTITY PASS'));
  }, skip: !Platform.isWindows);

  test('the routing script parses as Windows PowerShell reads it', () async {
    // Regression: written without a BOM, `powershell -File` decoded the
    // Chinese device patterns as GB2312 and the script failed to parse.
    final temp = await Directory.systemTemp.createTemp('yinwei-route-parse-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}route.ps1');
    await writeRouteScript(file);
    final bytes = await file.readAsBytes();
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$t = $null; $e = $null; '
          r'[void][System.Management.Automation.Language.Parser]::ParseFile('
          "'${file.path}'"
          r', [ref]$t, [ref]$e); $e.Count'
    ]).timeout(const Duration(seconds: 25));
    expect((result.stdout as String).trim(), '0',
        reason: '${result.stdout} ${result.stderr}');
  }, skip: !Platform.isWindows);
}
