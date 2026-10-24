import 'listen_tap_trace.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_protocol.dart';

typedef SodaLaunchIdentity = ({String command, List<String> runningPaths});

/// Dispatches one validated catalog track to the already-running Soda app.
/// No shell, media keys, playback polling or retry is used. Success only means
/// that the request was submitted; Soda still decides whether it can play it.
class SodaTrackLauncher {
  SodaTrackLauncher({
    Future<SodaLaunchIdentity> Function()? inspect,
    Future<void> Function(String executable, List<String> arguments)? launch,
    bool Function(String path)? exists,
    bool? supported,
    DateTime Function()? clock,
  })  : _inspect = inspect ?? SodaIdentityHelper.shared.inspect,
        _launch = launch ?? _launchWindows,
        _exists = exists ?? ((path) => File(path).existsSync()),
        _supported = supported ?? Platform.isWindows,
        _now = clock ?? DateTime.now {
    // Start the ready PowerShell now, so even the first tap from the iPad's
    // quick menu (which never browses, so never prefetches) answers fast.
    if (inspect == null && _supported) SodaIdentityHelper.shared.warmUp();
  }

  /// How long a handler/running-app reading is reused. The reading starts a
  /// PowerShell and takes 4–7 s on a busy laptop, so a tap reuses the one
  /// [prefetch] made when the music sheet opened.
  static const identityFreshFor = Duration(seconds: 15);

  final DateTime Function() _now;
  SodaLaunchIdentity? _identity;
  DateTime? _identityAt;
  Future<SodaLaunchIdentity>? _reading;

  bool get _fresh =>
      _identity != null &&
      _now().difference(_identityAt!) < identityFreshFor;

  /// Reads the handler and running 汽水 copies ahead of a tap. Failures are
  /// ignored here; [play] reads again.
  void prefetch() {
    if (!_supported || _fresh) return;
    _read().then((_) {}, onError: (Object _) {});
  }

  Future<SodaLaunchIdentity> _read() {
    return _reading ??= () async {
      try {
        final value = await _inspect();
        _identity = value;
        _identityAt = _now();
        return value;
      } finally {
        _reading = null;
      }
    }();
  }

  final Future<SodaLaunchIdentity> Function() _inspect;
  final Future<void> Function(String, List<String>) _launch;
  final bool Function(String) _exists;
  final bool _supported;

  Future<void> play(String trackId,
      {required void Function() beforeDispatch,
      Future<void> Function()? revalidateSelection}) async {
    ListenTapTrace.mark('host.launcher.start');
    if (!_supported) throw const RemoteFailure('soda_unavailable');
    final idMatch = RegExp(r'[0-9]{1,32}').matchAsPrefix(trackId);
    if (idMatch == null || idMatch.end != trackId.length) {
      throw const RemoteFailure('soda_invalid_selection');
    }
    // A remembered reading that no longer passes is read again once, so a
    // changed handler or a restarted 汽水 is never judged on old data.
    var cached = _fresh;
    late String executable;
    while (true) {
      SodaLaunchIdentity identity;
      try {
        identity = cached ? _identity! : await _read();
      } catch (_) {
        throw const RemoteFailure('soda_handler_unavailable');
      }
      try {
        executable = _validExecutable(identity);
        break;
      } on RemoteFailure {
        if (!cached) rethrow;
        cached = false;
        _identity = null;
      }
    }
    final uri = Uri(
      scheme: 'luna',
      host: 'luna.com',
      path: '/playing',
      queryParameters: {'track_id': trackId, 'media_type': 'track'},
    );
    // Registry inspection may wait for its helper. Fence account, catalog and
    // selection again after that wait, before the final synchronous lease guard.
    ListenTapTrace.mark('host.launcher.identity');
    await revalidateSelection?.call();
    ListenTapTrace.mark('host.launcher.revalidated');
    // Last synchronous guard after all account/catalog/registry preparation.
    // A refusal here is definitely before dispatch and can safely be reported.
    beforeDispatch();
    try {
      ListenTapTrace.mark('host.handoff.start');
      await _launch(executable, ['--', uri.toString()]);
      ListenTapTrace.mark('host.handoff.submitted');
    } catch (_) {
      // Never label an ambiguous external dispatch as a pre-action lease/state
      // refusal: clients must not repeat a possibly submitted playback action.
      throw const RemoteFailure('soda_dispatch_uncertain');
    }
  }

  String _validExecutable(SodaLaunchIdentity identity) {
    // This exact fixed template is the observed installed luna handler. Refuse
    // alternate flags, executables and substitutions rather than interpreting
    // a registry command line through a shell.
    final match = RegExp(r'^"([^"\r\n]+)" "--" "%1"$')
        .firstMatch(identity.command.trim());
    final executable = match?.group(1);
    if (executable == null ||
        !File(executable).isAbsolute ||
        executable.split(RegExp(r'[/\\]')).last.toLowerCase() !=
            'sodamusic.exe' ||
        !_exists(executable)) {
      throw const RemoteFailure('soda_handler_changed');
    }
    if (!identity.runningPaths
        .any((path) => path.toLowerCase() == executable.toLowerCase())) {
      throw const RemoteFailure('soda_not_running');
    }
    return executable;
  }

  /// One-off reading in a new PowerShell (4–7 s on a busy laptop). Only the
  /// fallback now: [SodaIdentityHelper] answers the same query in milliseconds.
  static Future<SodaLaunchIdentity> inspectOnce() => _inspectWindows();

  static SodaLaunchIdentity parseIdentity(String json) {
    final value = jsonDecode(json);
    if (value is! Map ||
        value['command'] is! String ||
        value['runningPaths'] is! List) {
      throw const FormatException('invalid_soda_handler');
    }
    return (
      command: value['command'] as String,
      runningPaths: (value['runningPaths'] as List).whereType<String>().toList()
    );
  }

  static Future<SodaLaunchIdentity> _inspectWindows() async {
    const script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$key = Get-Item -LiteralPath 'Registry::HKEY_CLASSES_ROOT\luna\shell\open\command'
$paths = @(Get-Process -Name SodaMusic -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Where-Object { $_ })
@{ command = $key.GetValue(''); runningPaths = $paths } | ConvertTo-Json -Compress
''';
    final bytes = <int>[];
    for (final unit in script.codeUnits) {
      bytes.addAll([unit & 255, unit >> 8]);
    }
    // The script is constant; no registry value or remote selection is ever
    // interpolated into PowerShell code.
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64Encode(bytes)
    ]);
    final stdout = utf8.decoder.bind(process.stdout).join();
    final stderr = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 8));
      await stderr;
      if (code != 0) throw const FormatException('invalid_soda_handler');
      return parseIdentity(await stdout);
    } catch (_) {
      process.kill(); // Only our bounded read-only helper, never the music app.
      rethrow;
    }
  }

  static Future<void> _launchWindows(
      String executable, List<String> args) async {
    await Process.start(executable, args,
        mode: ProcessStartMode.detached, runInShell: false);
  }
}

/// Answers [SodaTrackLauncher]'s handler/running-app question from one
/// PowerShell kept ready, like RemoteMediaKeys does for play/pause.
///
/// Measured on the owner's iPad (2026-10-24): a quick-menu tap waited 7.9 s on
/// the laptop, almost all of it starting a new PowerShell for this reading.
/// The query itself (one registry value, SodaMusic process paths) takes
/// milliseconds. The script is constant; nothing from a remote is ever written
/// into it. Any helper failure falls back to the one-off reading.
class SodaIdentityHelper {
  SodaIdentityHelper({
    Future<Process> Function()? start,
    Future<SodaLaunchIdentity> Function()? fallback,
    this.timeout = const Duration(seconds: 8),
  })  : _startProcess = start ?? _startHelper,
        _fallback = fallback ?? SodaTrackLauncher.inspectOnce;

  static final shared = SodaIdentityHelper();

  final Future<Process> Function() _startProcess;
  final Future<SodaLaunchIdentity> Function() _fallback;
  final Duration timeout;

  Process? _process;
  StreamIterator<String>? _lines;
  Future<void> _queue = Future.value();

  /// Starts the helper ahead of the first tap. Failures are ignored here.
  void warmUp() {
    _enqueue(() => _ready().then((_) {}, onError: (Object _) => _reset()))
        .ignore();
  }

  Future<SodaLaunchIdentity> inspect() => _enqueue(() async {
        try {
          final lines = await _ready();
          _process!.stdin.write('Get-YinweiSodaIdentity\r\n');
          await _process!.stdin.flush();
          if (!await lines.moveNext().timeout(timeout)) {
            throw StateError('closed');
          }
          return SodaTrackLauncher.parseIdentity(lines.current.trim());
        } catch (_) {
          _reset();
          return _fallback();
        }
      });

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<StreamIterator<String>> _ready() async {
    final existing = _lines;
    if (existing != null) return existing;
    final process = await _startProcess();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stderr.drain<void>().ignore();
    _process = process;
    _lines = lines;
    process.stdin.write(". '${_scriptPath.replaceAll("'", "''")}'\r\n");
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 20)) ||
        lines.current.trim() != 'ready') {
      throw StateError('helper did not start');
    }
    return lines;
  }

  void _reset() {
    _process?.kill(); // Only this read-only helper, never the music app.
    _process = null;
    _lines = null;
  }

  static final _scriptPath = '${Directory.systemTemp.path}'
      '${Platform.pathSeparator}yinwei_soda_identity_v1.ps1';

  static Future<Process> _startHelper() async {
    // UTF-8 BOM so Windows PowerShell 5.1 reads the script as UTF-8.
    await File(_scriptPath)
        .writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script)], flush: true);
    return Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '-',
    ]);
  }

  // Same reading as the one-off script in SodaTrackLauncher, one JSON line per
  // request ('error' on failure, which the caller treats as a failed reading).
  static const _script = r'''
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# Listing processes by name took ~600 ms on the owner's busy laptop and
# Process.Path walks every module; a native scan of image names takes a few
# milliseconds. Compiled once, when the helper starts.
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text; using System.Runtime.InteropServices;
public static class YinweiImage {
  [DllImport("psapi.dll", SetLastError = true)] static extern bool EnumProcesses([Out] int[] ids, int size, out int needed);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static string[] Paths(string exe) {
    var ids = new int[8192]; int needed;
    var found = new List<string>();
    if (!EnumProcesses(ids, ids.Length * 4, out needed)) return found.ToArray();
    for (int i = 0; i < needed / 4; i++) {
      IntPtr h = OpenProcess(0x1000, false, ids[i]); // query limited information
      if (h == IntPtr.Zero) continue;
      try {
        var b = new StringBuilder(1024); int n = b.Capacity;
        if (QueryFullProcessImageName(h, 0, b, ref n)) {
          string path = b.ToString(0, n);
          if (string.Equals(Path.GetFileName(path), exe, StringComparison.OrdinalIgnoreCase) && !found.Contains(path)) found.Add(path);
        }
      } finally { CloseHandle(h); }
    }
    return found.ToArray();
  }
}
'@
function Get-YinweiSodaIdentity {
  $line = 'error'
  try {
    $key = Get-Item -LiteralPath 'Registry::HKEY_CLASSES_ROOT\luna\shell\open\command' -ErrorAction Stop
    $paths = @([YinweiImage]::Paths('SodaMusic.exe'))
    $line = @{ command = $key.GetValue(''); runningPaths = $paths } | ConvertTo-Json -Compress
  } catch { $line = 'error' }
  [Console]::Out.WriteLine($line); [Console]::Out.Flush()
}
[Console]::Out.WriteLine('ready'); [Console]::Out.Flush()
''';
}
