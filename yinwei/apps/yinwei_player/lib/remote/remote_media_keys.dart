import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Play/pause/next/previous for the Live source app from a remote, through
/// one PowerShell kept ready: starting PowerShell and Windows media controls
/// for every tap took about 1.5 s; a ready one answers in milliseconds.
/// Same session choice as [SystemMediaService.sendCommand], which stays the
/// fallback (and the path the laptop's own controls use).
///
/// A refusal by the app (or no media session) throws, as the one-off command
/// does; anything else wrong with the helper falls back to the one-off
/// command and starts a fresh helper next time.
class RemoteMediaKeys {
  RemoteMediaKeys({
    required this.fallback,
    Future<Process> Function()? start,
    this.timeout = const Duration(seconds: 6),
  }) : _startProcess = start ?? _startHelper;

  final Future<void> Function(String action) fallback;
  final Duration timeout;
  final Future<Process> Function() _startProcess;

  Process? _process;
  StreamIterator<String>? _lines;
  Future<void> _queue = Future.value();
  bool _closed = false;

  static const actions = {'play', 'pause', 'next', 'previous'};

  /// Sends one key; commands run one at a time, in order.
  Future<void> send(String action) {
    if (!actions.contains(action)) {
      throw ArgumentError.value(action, 'action');
    }
    return _enqueue(() => _send('Send-YinweiKey $action',
        fallbackAction: () => fallback(action)));
  }

  /// Jumps to [seconds] in the current song. The music app may refuse it
  /// (ProcessException); there is no one-off command to fall back to.
  Future<void> seek(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      throw ArgumentError.value(seconds, 'seconds');
    }
    return _enqueue(() => _send('Send-YinweiSeek ${seconds.toStringAsFixed(3)}',
        fallbackAction: () async =>
            throw StateError('media helper unavailable')));
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _send(String line,
      {required Future<void> Function() fallbackAction}) async {
    String reply;
    try {
      final lines = await _ready();
      _process!.stdin.write('$line\r\n');
      await _process!.stdin.flush();
      if (!await lines.moveNext().timeout(timeout)) throw StateError('closed');
      reply = lines.current.trim();
    } catch (_) {
      _reset();
      return fallbackAction();
    }
    if (reply == 'ok') return;
    if (reply == 'refused' || reply == 'nosession') {
      throw ProcessException('media', [line], reply, 2);
    }
    _reset();
    return fallbackAction();
  }

  Future<StreamIterator<String>> _ready() async {
    if (_closed) throw StateError('closed');
    final existing = _lines;
    if (existing != null) return existing;
    final process = await _startProcess();
    final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    process.stderr.drain<void>().ignore();
    _process = process;
    _lines = lines;
    // Command mode runs each input line as it arrives (a script run with
    // -File only sees its input once the input closes). Load the script,
    // which says "ready" once Windows media controls are loaded.
    process.stdin.write(". '${_scriptPath.replaceAll("'", "''")}'\r\n");
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 15)) ||
        lines.current.trim() != 'ready') {
      throw StateError('helper did not start');
    }
    return lines;
  }

  /// Starts the helper ahead of the first tap (its start takes ~1.5 s).
  Future<void> warmUp() {
    final run = _queue.then((_) => _ready().then((_) {}, onError: (_) {
          _reset();
        }));
    _queue = run;
    return run;
  }

  void _reset() {
    _process?.kill();
    _process = null;
    _lines = null;
  }

  void close() {
    _closed = true;
    _reset();
  }

  static final _scriptPath = '${Directory.systemTemp.path}'
      '${Platform.pathSeparator}yinwei_media_keys_v3.ps1';

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

  /// Loaded once; then each `Send-YinweiKey <action>` line answers
  /// ok / refused / nosession / error. PowerShell exits when its input
  /// closes (the player is gone). Session choice as in SystemMediaService's
  /// media command: Playing beats Paused beats others.
  static const _script = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$methods = @{ play = 'TryPlayAsync'; pause = 'TryPauseAsync'; next = 'TrySkipNextAsync'; previous = 'TrySkipPreviousAsync' }
function Send-YinweiKey([string]$line) {
  $reply = 'error'
  try {
    $method = $methods[$line.Trim()]
    if ($method) {
      $best = $null; $bestScore = 0
      foreach ($s in $mgr.GetSessions()) {
        $st = [string]$s.GetPlaybackInfo().PlaybackStatus
        $score = 1
        if ($st -eq 'Playing') { $score = 3 } elseif ($st -eq 'Paused') { $score = 2 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $s }
      }
      if (-not $best) { $reply = 'nosession' }
      elseif (Await ($best.$method()) ([bool])) { $reply = 'ok' }
      else { $reply = 'refused' }
    }
  } catch { $reply = 'error' }
  [Console]::Out.WriteLine($reply); [Console]::Out.Flush()
}
function Send-YinweiSeek([double]$seconds) {
  $reply = 'error'
  try {
    $best = $null; $bestScore = 0
    foreach ($s in $mgr.GetSessions()) {
      $st = [string]$s.GetPlaybackInfo().PlaybackStatus
      $score = 1
      if ($st -eq 'Playing') { $score = 3 } elseif ($st -eq 'Paused') { $score = 2 }
      if ($score -gt $bestScore) { $bestScore = $score; $best = $s }
    }
    if (-not $best) { $reply = 'nosession' }
    elseif (Await ($best.TryChangePlaybackPositionAsync([long]($seconds * 10000000))) ([bool])) { $reply = 'ok' }
    else { $reply = 'refused' }
  } catch { $reply = 'error' }
  [Console]::Out.WriteLine($reply); [Console]::Out.Flush()
}
[Console]::Out.WriteLine('ready'); [Console]::Out.Flush()
''';
}
