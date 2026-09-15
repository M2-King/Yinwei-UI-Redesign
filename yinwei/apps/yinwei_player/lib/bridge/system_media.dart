import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Snapshot of Windows System Media Transport Controls (SMTC) session.
class SystemMediaState {
  const SystemMediaState({
    required this.active,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.playing = false,
    this.positionSec = 0,
    this.durationSec = 0,
    this.sourceApp = '',
    this.pid = 0,
    this.processName = '',
  });

  final bool active;
  final String title;
  final String artist;
  final String album;
  final bool playing;
  final double positionSec;
  final double durationSec;
  final String sourceApp;
  final int pid;
  final String processName;

  static const empty = SystemMediaState(active: false);

  bool get hasTrack => active && title.isNotEmpty;
}

/// AUMID → loopback exe pattern. Keep in sync with `_kPidResolveScript`.
///
/// 汽水 SMTC reports `SourceAppUserModelId` as the display name `汽水音乐`,
/// not `SodaMusic.exe`. Fragment-matching that string never finds a PID.
class SmtcLoopbackPicker {
  SmtcLoopbackPicker._();

  static const musicProcessPatterns = <String>[
    'SodaMusic',
    'cloudmusic',
    'Spotify',
    'QQMusic',
    'lyrica',
    'Kugou',
    'kwmplayer',
    'kuwo',
    'Music.UI',
    'NetEase',
  ];

  static const excludeProcess = <String>[
    'yinwei_player',
    'flutter',
    'dart',
    'powershell',
    'pwsh',
    'WindowsTerminal',
    'OpenConsole',
    'Cursor',
  ];

  /// Known display-name / AUMID → exe basename to search with Get-CimInstance.
  static String? processPatternForAumid(String source) {
    final s = source.trim();
    if (s.isEmpty) return null;
    final lower = s.toLowerCase();
    if (s.contains('汽水') || lower.contains('soda')) return 'SodaMusic';
    if (s.contains('网易云') ||
        lower.contains('cloudmusic') ||
        lower.contains('netease')) {
      return 'cloudmusic';
    }
    if (lower.contains('spotify')) return 'Spotify';
    if (lower.contains('qqmusic') || s.contains('QQ音乐')) return 'QQMusic';
    if (lower.contains('kugou') || s.contains('酷狗')) return 'Kugou';
    if (lower.contains('kuwo') ||
        lower.contains('kwmplayer') ||
        s.contains('酷我')) {
      return 'kwmplayer';
    }
    if (lower.contains('lyrica')) return 'lyrica';
    return null;
  }

  /// Empty or CJK-only AUMIDs cannot fragment-match `SodaMusic.exe`.
  static bool shouldScanAllMusicApps(String source) {
    final s = source.trim();
    if (s.isEmpty) return true;
    return !RegExp(r'[A-Za-z]{3,}').hasMatch(s);
  }

  static bool looksLikeBrowser(String source) {
    return RegExp(
      r'chrome|msedge|firefox|Edge|Brave',
      caseSensitive: false,
    ).hasMatch(source);
  }

  static bool isExcludedProcess(String name) {
    final base = name.toLowerCase().replaceAll('.exe', '');
    return excludeProcess.any((e) => e.toLowerCase() == base);
  }
}

/// Persistent PowerShell SMTC daemon — loads WinRT once, then streams JSON lines.
class SystemMediaService extends ChangeNotifier {
  SystemMediaState state = SystemMediaState.empty;
  String? lastError;
  bool warming = false;
  bool ready = false;
  DateTime? lastActiveAt;

  static const sessionStaleAfter = Duration(seconds: 6);

  /// True while we have seen an `active` SMTC line recently.
  /// Volume keys often emit `no_session` for a tick; that must not wipe state.
  bool get sessionFresh {
    final t = lastActiveAt;
    if (t == null) return false;
    return DateTime.now().difference(t) < sessionStaleAfter;
  }

  Process? _proc;
  StreamSubscription<String>? _sub;
  StreamSubscription<String>? _errSub;
  Completer<void>? _readyGate;

  /// Starts background daemon (call once at app launch — before Island).
  Future<void> start() async {
    if (!Platform.isWindows) return;
    if (_proc != null) return;
    warming = true;
    ready = false;
    notifyListeners();
    _readyGate = Completer<void>();
    try {
      final script = await _ensureDaemonScript();
      _proc = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
        ],
        mode: ProcessStartMode.normal,
      );
      _sub = _proc!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (e) {
        lastError = e.toString();
        notifyListeners();
      });
      _errSub = _proc!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {});
      // Hard timeout so UI never sits forever on first WinRT load.
      unawaited(() async {
        await Future<void>.delayed(const Duration(seconds: 20));
        if (_readyGate != null && !_readyGate!.isCompleted) {
          warming = false;
          ready = true;
          _readyGate!.complete();
          notifyListeners();
        }
      }());
    } catch (e) {
      warming = false;
      lastError = e.toString();
      notifyListeners();
      _readyGate?.complete();
    }
  }

  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (ready) return;
    final gate = _readyGate;
    if (gate == null) {
      await start();
    }
    await (_readyGate?.future)?.timeout(timeout, onTimeout: () {});
  }

  void stop() {
    _sub?.cancel();
    _errSub?.cancel();
    _sub = null;
    _errSub = null;
    _proc?.kill();
    _proc = null;
    warming = false;
  }

  Future<void> togglePlayPause() async {
    if (!Platform.isWindows) return;
    await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        _kToggleScript,
      ],
    );
  }

  /// Intentionally a no-op.
  ///
  /// Muting / zeroing the music app session (ISimpleAudioVolume) makes many
  /// players (汽水音乐, Spotify, …) auto-pause within a few seconds. Live HRTF
  /// therefore overlays wet Spatial on top of dry source audio instead.
  Future<void> setSourceMuted(bool muted) async {
    assert(() {
      // Keep API for Island callers; never touch session volume.
      debugPrint('setSourceMuted($muted) ignored — mute pauses music apps');
      return true;
    }());
  }

  void _onLine(String line) {
    final raw = line.trim();
    if (raw.isEmpty) return;
    if (raw == 'YINWEI_SMTC_READY') {
      warming = false;
      ready = true;
      if (_readyGate != null && !_readyGate!.isCompleted) {
        _readyGate!.complete();
      }
      notifyListeners();
      return;
    }
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return;
    try {
      final map =
          jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      if (map['status'] != 'active') {
        // Volume keys, BT renegotiate, and next-track often emit no_session
        // for a tick. Wiping here made Live Transfer auto-stop.
        return;
      }
      lastActiveAt = DateTime.now();
      final rawStatus = map['playbackStatus'] as String? ?? '';
      _set(SystemMediaState(
        active: true,
        title: _b64(map['title']),
        artist: _b64(map['artist']),
        album: _b64(map['album']),
        playing: _coercePlaying(rawStatus, state.playing),
        positionSec: (map['position'] as num?)?.toDouble() ?? 0,
        durationSec: (map['duration'] as num?)?.toDouble() ?? 0,
        sourceApp: map['source'] as String? ?? '',
        pid: (map['pid'] as num?)?.toInt() ?? 0,
        // Empty process name is OK when pid>0 (Start Transfer keys off pid).
        processName: map['process'] as String? ?? '',
      ));
      lastError = null;
      if (!ready) {
        warming = false;
        ready = true;
        if (_readyGate != null && !_readyGate!.isCompleted) {
          _readyGate!.complete();
        }
      }
    } catch (e) {
      lastError = e.toString();
    }
  }

  void _set(SystemMediaState next) {
    final changed = next.active != state.active ||
        next.title != state.title ||
        next.artist != state.artist ||
        next.playing != state.playing ||
        next.pid != state.pid ||
        next.processName != state.processName ||
        (next.positionSec - state.positionSec).abs() > 0.35;
    state = next;
    if (changed) notifyListeners();
  }

  /// Test hook: feed one daemon JSON line (must stay a real file).
  @visibleForTesting
  void applyDaemonLine(String line) => _onLine(line);

  /// Volume / device hops report Changing or Opened — not a real pause.
  static bool coercePlaying(String status, bool previous) {
    switch (status) {
      case 'Playing':
        return true;
      case 'Changing':
      case 'Opened':
        return previous;
      default:
        return false;
    }
  }

  bool _coercePlaying(String status, bool previous) =>
      coercePlaying(status, previous);

  static String _b64(dynamic v) {
    final s = v as String? ?? '';
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(s));
    } catch (_) {
      return s;
    }
  }

  /// One-shot PID resolve when the daemon still reports pid=0.
  /// Prefers MAIN Electron (no `--type=`) so include-tree covers audio children.
  Future<({int pid, String name})?> resolveLoopbackPid(String source) async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          '$_kPidResolveScript\n$_kProbePidCommand',
        ],
        environment: {'YINWEI_SMTC_SRC': source},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final raw = result.stdout.toString().trim();
      final start = raw.lastIndexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final map =
          jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final pid = (map['pid'] as num?)?.toInt() ??
          (map['Pid'] as num?)?.toInt() ??
          0;
      final name = (map['name'] as String?) ??
          (map['Name'] as String?) ??
          '';
      if (pid <= 0) return null;
      if (SmtcLoopbackPicker.isExcludedProcess(name)) return null;
      return (pid: pid, name: name);
    } catch (_) {
      return null;
    }
  }

  Future<String> _ensureDaemonScript() async {
    final dir = await getTemporaryDirectory();
    final sep = Platform.pathSeparator;
    final file = File('${dir.path}$sep$_kDaemonFileName');
    // UTF-8 BOM so Windows PowerShell 5.1 -File reads the script as UTF-8.
    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_kDaemonScript)];
    await file.writeAsBytes(bytes, flush: true);
    try {
      await File('${dir.path}${sep}yinwei_smtc_daemon.ps1').delete();
    } catch (_) {}
    return file.path;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

const _kDaemonFileName = 'yinwei_smtc_daemon_v2.ps1';

const _kDaemonScript =
    '$_kDaemonScriptHead$_kPidResolveScript$_kDaemonScriptTail';

const _kProbePidCommand = r'''
$resolved = Resolve-Pid $env:YINWEI_SMTC_SRC
$resolved | ConvertTo-Json -Compress
''';

const _kDaemonScriptHead = r'''
$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}
''';

/// Shared by the SMTC daemon and the one-shot Start Transfer probe.
/// Keep aliases in sync with [SmtcLoopbackPicker].
const _kPidResolveScript = r'''
function Select-LoopbackPid([string]$pattern, [string[]]$exclude) {
  # WASAPI process loopback + include-tree only covers this PID and its children.
  # Electron/Chromium apps (汽水, etc.) spawn many SodaMusic.exe: MAIN has the tree;
  # Get-Process | Select -First 1 often returns a --type=renderer with no audio.
  if ([string]::IsNullOrWhiteSpace($pattern)) { return $null }
  if ($null -eq $exclude) { $exclude = @() }
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) {
    $all = @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue)
  }
  $rows = @($all | Where-Object {
    if (-not $_.Name) { return $false }
    $base = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    if ($exclude -contains $base) { return $false }
    return ($base -like "*$pattern*")
  })
  if ($rows.Count -eq 0) { return $null }
  $mains = @($rows | Where-Object { [string]$_.CommandLine -notmatch '--type=' })
  $pool = if ($mains.Count -gt 0) { $mains } else { $rows }
  $poolPids = @($pool | ForEach-Object { $_.ProcessId })
  $roots = @($pool | Where-Object { $poolPids -notcontains $_.ParentProcessId })
  $pick = if ($roots.Count -gt 0) { $roots[0] } else { $pool[0] }
  return @{
    pid = [int]$pick.ProcessId
    name = [IO.Path]::GetFileNameWithoutExtension($pick.Name)
  }
}
function Resolve-Pid([string]$src) {
  $musicHints = @('SodaMusic','cloudmusic','Spotify','QQMusic','lyrica','Kugou','kwmplayer','kuwo','Music.UI','NetEase')
  $browserHints = @('chrome','msedge','firefox','ApplicationFrameHost')
  $exclude = @('yinwei_player','flutter','dart','powershell','pwsh','WindowsTerminal','OpenConsole','Cursor')
  $srcL = [string]$src

  # CJK display AUMIDs as char codes so this .ps1 is encoding-safe.
  $cjkSoda = ([char]0x6C7D).ToString() + ([char]0x6C34).ToString()
  $cjkNetease = ([char]0x7F51).ToString() + ([char]0x6613).ToString() + ([char]0x4E91).ToString()
  $cjkQqMusic = 'QQ' + ([char]0x97F3).ToString() + ([char]0x4E50).ToString()
  $cjkKugou = ([char]0x9177).ToString() + ([char]0x72D7).ToString()
  $cjkKuwo = ([char]0x9177).ToString() + ([char]0x6211).ToString()

  # 1) Known aliases. 汽水 reports SourceAppUserModelId = 汽水音乐, not SodaMusic.
  if ($srcL) {
    if ($srcL.Contains($cjkSoda) -or $srcL -match 'Soda') {
      $hit = Select-LoopbackPid 'SodaMusic' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL.Contains($cjkNetease) -or $srcL -match 'cloudmusic|NetEase|Netease') {
      $hit = Select-LoopbackPid 'cloudmusic' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
      $hit = Select-LoopbackPid 'NetEase' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL.Contains($cjkQqMusic) -or $srcL -match 'QQMusic') {
      $hit = Select-LoopbackPid 'QQMusic' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL.Contains($cjkKugou) -or $srcL -match 'Kugou') {
      $hit = Select-LoopbackPid 'Kugou' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL.Contains($cjkKuwo) -or $srcL -match 'kwmplayer|kuwo') {
      $hit = Select-LoopbackPid 'kwmplayer' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
      $hit = Select-LoopbackPid 'kuwo' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL -match 'Spotify') {
      $hit = Select-LoopbackPid 'Spotify' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
    if ($srcL -match 'lyrica') {
      $hit = Select-LoopbackPid 'lyrica' $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
  }

  # 2) Fragments from AUMID (SpotifyAB.SpotifyMusic_xxx). Skip yinwei/flutter.
  if ($srcL) {
    foreach ($p in ($srcL -split '[.!_ \-]')) {
      if ($p -and $p.Length -ge 3 -and $p -notmatch '^\d+$') {
        $skip = @('exe','App','Application','Package','Windows','Microsoft','UWP','Win32','x64','x86','Prod')
        if ($skip -contains $p) { continue }
        if ($exclude -contains $p) { continue }
        $hit = Select-LoopbackPid $p $exclude
        if ($hit -and [int]$hit.pid -gt 0) { return $hit }
      }
    }
  }

  # 3) Music apps before browsers. Empty / CJK-only AUMID still scans hints
  # (fragment 汽水音乐 never matches SodaMusic.exe). Latin AUMID only
  # matches hints contained in the source, so a leftover 汽水 is not stolen.
  $hasLatin = $srcL -match '[A-Za-z]{3,}'
  if (-not $srcL -or -not $hasLatin) {
    foreach ($h in $musicHints) {
      $hit = Select-LoopbackPid $h $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
  } else {
    foreach ($h in $musicHints) {
      if ($srcL -match $h) {
        $hit = Select-LoopbackPid $h $exclude
        if ($hit -and [int]$hit.pid -gt 0) { return $hit }
      }
    }
  }

  # 4) Browsers only if AUMID looks like a browser.
  if ($srcL -match 'chrome|msedge|firefox|Edge|Brave') {
    foreach ($h in $browserHints) {
      $hit = Select-LoopbackPid $h $exclude
      if ($hit -and [int]$hit.pid -gt 0) { return $hit }
    }
  }
  return @{ pid = 0; name = '' }
}
''';

const _kDaemonScriptTail = r'''
function Emit-Once {
  [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
  $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
  $sessions = $mgr.GetSessions()
  if ($sessions.Count -eq 0) { Write-Output '{"status":"no_session"}'; return }
  $currentSrc = ''
  try {
    $cur = $mgr.GetCurrentSession()
    if ($cur) { $currentSrc = [string]$cur.SourceAppUserModelId }
  } catch {}
  $best = $null; $bestScore = 0
  foreach ($s in $sessions) {
    $info = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    if ([string]::IsNullOrEmpty($info.Title)) { continue }
    $pb = $s.GetPlaybackInfo()
    $st = [string]$pb.PlaybackStatus
    $score = 1
    # Playing must beat a leftover Paused 汽水 session. Current session wins ties
    # so a newly started Spotify is not stuck behind the previous app.
    if ($st -eq 'Playing') { $score = 5 }
    elseif ($st -eq 'Changing' -or $st -eq 'Opened') { $score = 4 }
    elseif ($st -eq 'Paused') { $score = 2 }
    if ($currentSrc -and ([string]$s.SourceAppUserModelId) -eq $currentSrc) { $score += 2 }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $s }
  }
  if ($null -eq $best) { Write-Output '{"status":"no_session"}'; return }
  $info = Await ($best.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
  $playback = $best.GetPlaybackInfo()
  $timeline = $best.GetTimelineProperties()
  $src = [string]$best.SourceAppUserModelId
  $resolved = Resolve-Pid $src
  $obj = @{
    status = 'active'
    title = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$info.Title))
    artist = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$info.Artist))
    album = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$info.AlbumTitle))
    playbackStatus = [string]$playback.PlaybackStatus
    position = [math]::Round($timeline.Position.TotalSeconds, 2)
    duration = [math]::Round($timeline.EndTime.TotalSeconds, 2)
    source = $src
    pid = [int]$resolved.pid
    process = [string]$resolved.name
  }
  $obj | ConvertTo-Json -Compress
}

# Signal ready immediately so Flutter UI is not blocked on first WinRT load.
Write-Output 'YINWEI_SMTC_READY'
[Console]::Out.Flush()

while ($true) {
  try { Emit-Once } catch { Write-Output '{"status":"no_session"}' }
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 400
}
''';

const _kToggleScript = r'''
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
$sessions = $mgr.GetSessions()
$best = $null; $bestScore = 0
foreach ($s in $sessions) {
  $pb = $s.GetPlaybackInfo()
  $st = [string]$pb.PlaybackStatus
  $score = 1
  if ($st -eq 'Playing') { $score = 3 } elseif ($st -eq 'Paused') { $score = 2 }
  if ($score -gt $bestScore) { $bestScore = $score; $best = $s }
}
if ($best) { $best.TryTogglePlayPauseAsync().GetAwaiter().GetResult() | Out-Null }
''';
