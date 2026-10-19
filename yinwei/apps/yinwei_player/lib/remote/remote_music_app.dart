import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

/// A running music player process (its main process, not a helper).
typedef RunningMusicApp = ({int pid, String path, String process});

/// Remote "Start on laptop" when no music app has a song on the laptop: opens
/// the music app the laptop knows (by its `.exe` path) if it isn't running,
/// then presses its play/pause key (Space) in the app's own window until
/// Windows reports a song. The existing remote start then starts Live.
///
/// Many players (汽水音乐 among them) only appear in Windows media controls
/// once a song plays, so Windows can't be asked to press play on a freshly
/// opened app. Space is sent to that app's window only (a window message, no
/// focus change), so nothing else on the laptop receives it.
///
/// The laptop decides what opens, never the remote: only an allow-listed music
/// player, with its `.exe` path read from the laptop's own process table. The
/// remote command carries no path or name.
class RemoteMusicApp {
  RemoteMusicApp({
    required this.file,
    Future<String?> Function(int pid)? executablePath,
    Future<List<RunningMusicApp>> Function()? runningApps,
    Future<void> Function(String path)? launch,
    Future<bool> Function(List<int> pids)? pressPlay,
    bool Function(String path)? exists,
    this.readyTimeout = const Duration(seconds: 30),
    this.pressEvery = const Duration(seconds: 8),
    this.maxPresses = 3,
    this.poll = const Duration(milliseconds: 250),
  })  : _executablePath = executablePath ?? _processPath,
        _runningApps = runningApps ?? _listRunning,
        _launch = launch ?? _start,
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
  final Future<void> Function(String path) _launch;
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
        if (launchable(path) && _exists(path)) _app = (path: path, name: name);
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

  /// Opens the app if needed and presses play until [hasTrack]. Throws
  /// [RemoteFailure] with a code the iPad and the web page explain.
  Future<void> open(bool Function() hasTrack) async {
    final app = _app;
    if (app == null) throw const RemoteFailure('no_music_app');
    if (!_exists(app.path)) {
      _app = null;
      throw const RemoteFailure('no_music_app');
    }
    var launched = false;
    Future<void> launch() async {
      launched = true;
      try {
        await _launch(app.path);
      } catch (_) {
        throw const RemoteFailure('music_app_open_failed');
      }
    }

    if ((await _pids(app.path)).isEmpty) await launch();
    final deadline = DateTime.now().add(readyTimeout);
    var presses = 0;
    var next = DateTime.now();
    while (!hasTrack() && DateTime.now().isBefore(deadline)) {
      if (presses < maxPresses && !DateTime.now().isBefore(next)) {
        final pids = await _pids(app.path);
        var pressed = false;
        try {
          pressed = pids.isNotEmpty && await _pressPlay(pids);
        } catch (_) {
          // Treated as no window yet.
        }
        if (pressed) {
          presses++;
          next = DateTime.now().add(pressEvery);
        } else if (!launched) {
          // Running without a window to press in (hidden in the tray):
          // opening it again brings its window back.
          await launch();
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

  Future<List<int>> _pids(String path) async {
    try {
      final lower = path.toLowerCase();
      return [
        for (final app in await _runningApps())
          if (app.path.toLowerCase() == lower) app.pid,
      ];
    } catch (_) {
      return const [];
    }
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
  static Future<ProcessResult> _powershell(String script) {
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
      stdoutEncoding: utf8,
    );
  }

  static Future<String?> _processPath(int pid) async {
    final result = await _powershell(
        '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").ExecutablePath');
    final path = '${result.stdout}'.trim();
    return result.exitCode == 0 && path.isNotEmpty ? path : null;
  }

  /// Main processes of allow-listed players (Electron helpers carry --type=).
  static Future<List<RunningMusicApp>> _listRunning() async {
    final pattern = SmtcLoopbackPicker.musicProcessPatterns
        .map((p) => p.replaceAll('.', r'\.'))
        .join('|');
    final result = await _powershell('''
\$rows = @(Get-CimInstance Win32_Process | Where-Object {
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
