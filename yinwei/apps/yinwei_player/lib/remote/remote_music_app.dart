import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/bridge/native_process_list.dart';

/// A running music player process (its main process, not a helper).
typedef RunningMusicApp = ({int pid, String path, String process});

/// A Start Menu shortcut: the `.lnk` file, its target and its arguments.
typedef MusicShortcut = ({String lnk, String target, String args});

/// Remote "Start on laptop" when no music app has a song on the laptop: opens
/// the music app the laptop knows if no copy of it is running (through its
/// Start Menu shortcut, which survives app updates, or else its `.exe`), then
/// presses its play/pause key (Space) in the app's own window until Windows
/// reports a song. The existing remote start then starts Live.
///
/// Many players (汽水音乐 among them) only appear in Windows media controls
/// once a song plays, so Windows can't be asked to press play on a freshly
/// opened app, and they ignore keys while in the background: the window is
/// brought to the front for the key press (see [_postSpace]).
///
/// The laptop decides what opens, never the remote: only an allow-listed music
/// player, by an `.exe` path read from the laptop's own process table or a
/// shortcut in the Start Menu that points at one. The remote command carries
/// no path or name.
class RemoteMusicApp {
  RemoteMusicApp({
    required this.file,
    Future<String?> Function(int pid)? executablePath,
    Future<List<RunningMusicApp>> Function()? runningApps,
    Future<List<MusicShortcut>> Function()? shortcuts,
    Future<void> Function(String target)? launch,
    Future<bool> Function(List<int> pids)? pressPlay,
    bool Function(String path)? exists,
    this.readyTimeout = const Duration(seconds: 30),
    this.pressEvery = const Duration(seconds: 8),
    this.maxPresses = 3,
    this.poll = const Duration(milliseconds: 250),
  })  : _executablePath = executablePath ?? _processPath,
        _runningApps = runningApps ?? _listRunning,
        _shortcuts = shortcuts ?? _listShortcuts,
        _launch = launch ?? _open,
        _pressPlay = pressPlay ?? _postSpace,
        _exists = exists ?? ((path) => File(path).existsSync());

  /// Where the app is remembered (survives a laptop restart).
  final File file;
  final Duration readyTimeout;

  /// Space toggles play/pause, so it is pressed again only after Windows has
  /// had this long to report the song.
  final Duration pressEvery;
  final int maxPresses;
  final Duration poll;
  final Future<String?> Function(int pid) _executablePath;
  final Future<List<RunningMusicApp>> Function() _runningApps;
  final Future<List<MusicShortcut>> Function() _shortcuts;
  final Future<void> Function(String target) _launch;
  final Future<bool> Function(List<int> pids) _pressPlay;
  final bool Function(String path) _exists;

  ({String path, String name})? _app;
  int _seenPid = 0;

  /// The app a remote start would open, or null.
  String? get name => _app?.name;

  Future<void> load() async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      final path = data['path'], name = data['name'];
      if (path is String && name is String && name.isNotEmpty) {
        if (!launchable(path)) return;
        // After an update the versioned .exe may be gone, but the Start Menu
        // shortcut still opens the app.
        if (_exists(path) || await _shortcutFor(path) != null) {
          _app = (path: path, name: name);
        }
      }
    } catch (_) {
      // Nothing remembered yet, or an unreadable file: start empty.
    }
  }

  /// Called on every Windows media change; remembers a music app with a song.
  Future<void> observe(SystemMediaState state) async {
    if (!state.hasTrack || state.pid <= 0 || state.pid == _seenPid) return;
    _seenPid = state.pid;
    if (!isMusicProcess(state.processName)) return;
    String? path;
    try {
      path = await _executablePath(state.pid);
    } catch (_) {
      return;
    }
    if (path == null || !launchable(path)) return;
    await _remember((path: path, name: displayName(state)));
  }

  /// With nothing remembered yet: a music player that is open but silent
  /// (so not in Windows media controls) is found by its process.
  Future<void> discover() async {
    if (_app != null) return;
    List<RunningMusicApp> running;
    try {
      running = await _runningApps();
    } catch (_) {
      return;
    }
    for (final app in running) {
      if (isMusicProcess(app.process) && launchable(app.path)) {
        await _remember(
            (path: app.path, name: processDisplayName(app.process)));
        return;
      }
    }
  }

  Future<void> _remember(({String path, String name}) app) async {
    if (app == _app) return;
    _app = app;
    try {
      await file.parent.create(recursive: true);
      await file
          .writeAsString(jsonEncode({'path': app.path, 'name': app.name}));
    } catch (_) {
      // Still remembered for this run.
    }
  }

  /// Opens the app if no copy runs and presses play until [hasTrack]. Throws
  /// [RemoteFailure] with a code the iPad and the web page explain.
  /// [onPress] runs before the first key press (for the iPad's progress).
  Future<void> open(bool Function() hasTrack,
      {void Function()? onPress}) async {
    final app = _app;
    if (app == null) throw const RemoteFailure('no_music_app');
    var opened = false;
    Future<void> start(String target) async {
      opened = true;
      try {
        await _launch(target);
      } catch (_) {
        throw const RemoteFailure('music_app_open_failed');
      }
    }

    if ((await _copies(app.path)).isEmpty) {
      // Not running: the Start Menu shortcut, else the remembered .exe.
      final target =
          await _shortcutFor(app.path) ?? (_exists(app.path) ? app.path : null);
      if (target == null) {
        _app = null;
        throw const RemoteFailure('no_music_app');
      }
      await start(target);
    }
    final deadline = DateTime.now().add(readyTimeout);
    var presses = 0;
    var next = DateTime.now();
    while (!hasTrack() && DateTime.now().isBefore(deadline)) {
      if (presses < maxPresses && !DateTime.now().isBefore(next)) {
        final copies = await _copies(app.path);
        if (presses == 0 && copies.isNotEmpty) onPress?.call();
        var pressed = false;
        try {
          pressed = copies.isNotEmpty &&
              await _pressPlay([for (final c in copies) c.pid]);
        } catch (_) {
          // Treated as no window yet.
        }
        if (pressed) {
          presses++;
          next = DateTime.now().add(pressEvery);
        } else if (!opened && copies.isNotEmpty) {
          // Running without a window to press in (hidden in the tray):
          // opening that same copy again brings its window back.
          await start(copies.first.path);
          next = DateTime.now().add(const Duration(seconds: 2));
        } else {
          // Still starting: no window to press in yet.
          next = DateTime.now().add(const Duration(seconds: 1));
        }
      }
      await Future<void>.delayed(poll);
    }
    if (!hasTrack()) throw const RemoteFailure('music_app_no_song');
  }

  /// Running copies of the same player, from any install or version.
  Future<List<RunningMusicApp>> _copies(String path) async {
    final family = musicFamily(_baseName(path));
    if (family == null) return const [];
    try {
      return [
        for (final app in await _runningApps())
          if (launchable(app.path) && musicFamily(app.process) == family) app,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// A Start Menu shortcut, without arguments, to the same player (or its
  /// launcher), or null.
  Future<String?> _shortcutFor(String path) async {
    final family = musicFamily(_baseName(path));
    if (family == null) return null;
    try {
      for (final s in await _shortcuts()) {
        if (startMenuShortcut(s.lnk) &&
            s.args.trim().isEmpty &&
            launchable(s.target) &&
            isMusicProcess(_baseName(s.target)) &&
            musicFamily(_baseName(s.target)) == family &&
            _exists(s.lnk) &&
            _exists(s.target)) {
          return s.lnk;
        }
      }
    } catch (_) {
      // No shortcut list: the .exe is used.
    }
    return null;
  }

  static String _baseName(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.toLowerCase().endsWith('.exe')
        ? name.substring(0, name.length - 4)
        : name;
  }

  /// Which allow-listed player a process or file name belongs to
  /// (SodaMusic and SodaMusicLauncher are both "sodamusic").
  static String? musicFamily(String name) {
    final n = name.toLowerCase();
    for (final p in SmtcLoopbackPicker.musicProcessPatterns) {
      if (n.contains(p.toLowerCase())) return p.toLowerCase();
    }
    return null;
  }

  /// Only shortcuts in a Start Menu Programs folder (yours or all users').
  static bool startMenuShortcut(String lnk) {
    final lower = lnk.toLowerCase();
    return lower.endsWith('.lnk') &&
        lower.contains(r'\microsoft\windows\start menu\programs\');
  }

  /// The allow list Live Transfer already uses; never a browser or Yinwei.
  static bool isMusicProcess(String process) {
    final p = process.toLowerCase();
    if (p.isEmpty) return false;
    if (SmtcLoopbackPicker.excludeProcess.any((e) => p == e.toLowerCase())) {
      return false;
    }
    return SmtcLoopbackPicker.musicProcessPatterns
        .any((m) => p.contains(m.toLowerCase()));
  }

  /// A desktop `.exe` by absolute path. Store apps can't be started by path.
  static bool launchable(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.exe') &&
        RegExp(r'^[a-z]:\\', caseSensitive: false).hasMatch(path) &&
        !lower.contains(r'\windowsapps\');
  }

  /// 汽水 reports its display name; others report an `.exe` or Store id.
  static String displayName(SystemMediaState state) {
    final source = state.sourceApp.trim();
    if (source.isEmpty || source.contains('!') || source.contains(r'\')) {
      return processDisplayName(state.processName);
    }
    return source.toLowerCase().endsWith('.exe')
        ? source.substring(0, source.length - 4)
        : source;
  }

  /// The name people know a player by, from its process name.
  static String processDisplayName(String process) {
    final p = process.toLowerCase();
    for (final entry in const {
      'sodamusic': '汽水音乐',
      'cloudmusic': '网易云音乐',
      'qqmusic': 'QQ音乐',
      'kugou': '酷狗音乐',
      'kwmplayer': '酷我音乐',
      'kuwo': '酷我音乐',
    }.entries) {
      if (p.contains(entry.key)) return entry.value;
    }
    return process;
  }

  /// Yinwei's own settings (`YINWEI_*`, Flutter's) stay out of the app.
  static Map<String, String> launchEnvironment(Map<String, String> parent) =>
      Map.of(parent)
        ..removeWhere((key, _) {
          final k = key.toUpperCase();
          return k.startsWith('YINWEI_') || k.startsWith('FLUTTER_');
        });

  /// Runs [script] passed as -EncodedCommand (UTF-16LE base64), so no quote
  /// in it can be split by command-line parsing.
  static Future<ProcessResult> _powershell(String script,
      {Map<String, String>? environment}) {
    final full =
        '[Console]::OutputEncoding=[Text.UTF8Encoding]::new(\$false)\n$script';
    final utf16 = <int>[
      for (final unit in full.codeUnits) ...[unit & 0xff, unit >> 8],
    ];
    return Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        base64.encode(utf16)
      ],
      environment: environment,
      includeParentEnvironment: environment == null,
      stdoutEncoding: utf8,
    );
  }

  /// Shortcuts in your and all users' Start Menu Programs folders.
  static Future<List<MusicShortcut>> _listShortcuts() async {
    final result = await _powershell(r'''
$shell = New-Object -ComObject WScript.Shell
$rows = @(foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))) {
  if ($dir -and (Test-Path -LiteralPath $dir)) {
    Get-ChildItem -LiteralPath $dir -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
      $s = $shell.CreateShortcut($_.FullName)
      @{ lnk = $_.FullName; target = [string]$s.TargetPath; args = [string]$s.Arguments }
    }
  }
})
ConvertTo-Json -InputObject $rows -Compress''');
    if (result.exitCode != 0) return const [];
    final text = '${result.stdout}'.trim();
    final data = jsonDecode(text.isEmpty ? '[]' : text);
    return [
      for (final row in (data is List ? data : const []))
        if (row is Map &&
            row['lnk'] is String &&
            row['target'] is String &&
            row['args'] is String)
          (
            lnk: row['lnk'] as String,
            target: row['target'] as String,
            args: row['args'] as String
          ),
    ];
  }

  /// A shortcut opens the way a Start Menu click does; an `.exe` directly.
  static Future<void> _open(String target) async {
    if (!target.toLowerCase().endsWith('.lnk')) return _start(target);
    final quoted = "'${target.replaceAll("'", "''")}'";
    final result = await _powershell('Start-Process -FilePath $quoted',
        environment: launchEnvironment(Platform.environment));
    if (result.exitCode != 0) {
      throw ProcessException('Start-Process', [target], '', result.exitCode);
    }
  }

  @visibleForTesting
  static Future<String?> processPathForTest(int pid) => _processPath(pid);

  @visibleForTesting
  static Future<List<RunningMusicApp>> listRunningForTest() => _listRunning();

  static Future<String?> _processPath(int pid) async {
    // Native lookup first (WMI took ~21 s per query on the owner's laptop).
    final result = await _powershell('$kYinweiProcessListPs\n'
        'if (Use-YinweiProcList) { [YinweiProcList]::PathOf($pid) } '
        'else { (Get-CimInstance Win32_Process -Filter "ProcessId=$pid").ExecutablePath }');
    final path = '${result.stdout}'.trim();
    return result.exitCode == 0 && path.isNotEmpty ? path : null;
  }

  /// Main processes of allow-listed players (Electron helpers carry --type=).
  static Future<List<RunningMusicApp>> _listRunning() async {
    final pattern = SmtcLoopbackPicker.musicProcessPatterns
        .map((p) => p.replaceAll('.', r'\.'))
        .join('|');
    final result = await _powershell('''
$kYinweiProcessListPs
\$all = @(Get-YinweiProcesses -Match '^($pattern)')
if (\$script:YinweiProcFailed) { \$all = @(Get-CimInstance Win32_Process) }
\$rows = @(\$all | Where-Object {
  \$_.Name -match '^($pattern)' -and [string]\$_.CommandLine -notmatch '--type=' -and \$_.ExecutablePath
} | ForEach-Object { @{ pid = [int]\$_.ProcessId; path = [string]\$_.ExecutablePath;
  process = [IO.Path]::GetFileNameWithoutExtension(\$_.Name) } })
ConvertTo-Json -InputObject \$rows -Compress''');
    if (result.exitCode != 0) return const [];
    final data = jsonDecode(
        '${result.stdout}'.trim().isEmpty ? '[]' : '${result.stdout}');
    return [
      for (final row in (data is List ? data : const []))
        if (row is Map &&
            row['pid'] is int &&
            row['path'] is String &&
            row['process'] is String)
          (
            pid: row['pid'] as int,
            path: row['path'] as String,
            process: row['process'] as String
          ),
    ];
  }

  /// Presses Space in the visible titled window of [pids]: brings it to the
  /// front (the player ignores keys while in the background), posts Space to
  /// that window only, then puts the previous window back. Sends nothing
  /// unless the player is confirmed in front. Exit 3: no window to press in
  /// (still starting, or hidden in the tray).
  static Future<bool> _postSpace(List<int> pids) async {
    final result = await _powershell('''
Add-Type -Language CSharp @"
using System; using System.Threading; using System.Runtime.InteropServices;
public static class YinweiSpace {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  static bool Front(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);
    uint me = GetCurrentThreadId();
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    bool attached = fg != 0 && fg != me && AttachThreadInput(me, fg, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    if (attached) AttachThreadInput(me, fg, false);
    return GetForegroundWindow() == h;
  }
  public static int Press(int[] pids) {
    IntPtr best = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (best == IntPtr.Zero && Array.IndexOf(pids, (int)pid) >= 0 &&
          IsWindowVisible(h) && GetWindowTextLength(h) > 0) best = h;
      return true;
    }, IntPtr.Zero);
    if (best == IntPtr.Zero) return 3;
    IntPtr before = GetForegroundWindow();
    if (!Front(best)) return 4;
    Thread.Sleep(700);
    PostMessage(best, 0x0100, (IntPtr)0x20, (IntPtr)0x00390001);
    PostMessage(best, 0x0102, (IntPtr)0x20, (IntPtr)0x00390001);
    PostMessage(best, 0x0101, (IntPtr)0x20, (IntPtr)unchecked((int)0xC0390001));
    Thread.Sleep(1500);
    if (before != IntPtr.Zero && before != best) Front(before);
    return 0;
  }
}
"@
exit [YinweiSpace]::Press([int[]]@(${pids.join(',')}))''');
    return result.exitCode == 0;
  }

  static Future<void> _start(String path) async {
    await Process.start(
      path,
      const [],
      workingDirectory: File(path).parent.path,
      environment: launchEnvironment(Platform.environment),
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
  }
}
