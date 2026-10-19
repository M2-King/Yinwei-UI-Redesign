import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

/// Remote "Start on laptop" when no music app is open on the laptop: opens the
/// music app the laptop last saw playing, then waits for Windows to report it
/// with a song (the existing remote start presses play and starts Live).
///
/// The laptop decides what opens, never the remote: only an allow-listed music
/// player seen through Windows media controls, with its `.exe` path read from
/// the laptop's own process table. The remote command carries no path or name.
class RemoteMusicApp {
  RemoteMusicApp({
    required this.file,
    Future<String?> Function(int pid)? executablePath,
    Future<void> Function(String path)? launch,
    bool Function(String path)? exists,
    this.readyTimeout = const Duration(seconds: 20),
    this.poll = const Duration(milliseconds: 250),
  })  : _executablePath = executablePath ?? _processPath,
        _launch = launch ?? _start,
        _exists = exists ?? ((path) => File(path).existsSync());

  /// Where the app is remembered (survives a laptop restart).
  final File file;
  final Duration readyTimeout;
  final Duration poll;
  final Future<String?> Function(int pid) _executablePath;
  final Future<void> Function(String path) _launch;
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
    final app = (path: path, name: displayName(state));
    if (app == _app) return;
    _app = app;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'path': app.path, 'name': app.name}));
    } catch (_) {
      // Still remembered for this run.
    }
  }

  /// Opens the remembered app and waits until [hasTrack]. Throws
  /// [RemoteFailure] with a code the iPad and the web page explain.
  Future<void> open(bool Function() hasTrack) async {
    final app = _app;
    if (app == null) throw const RemoteFailure('no_music_app');
    if (!_exists(app.path)) {
      _app = null;
      throw const RemoteFailure('no_music_app');
    }
    try {
      await _launch(app.path);
    } catch (_) {
      throw const RemoteFailure('music_app_open_failed');
    }
    final deadline = DateTime.now().add(readyTimeout);
    while (!hasTrack() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
    }
    if (!hasTrack()) throw const RemoteFailure('music_app_no_song');
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
      return state.processName;
    }
    return source.toLowerCase().endsWith('.exe')
        ? source.substring(0, source.length - 4)
        : source;
  }

  /// Yinwei's own settings (`YINWEI_*`, Flutter's) stay out of the app.
  static Map<String, String> launchEnvironment(Map<String, String> parent) =>
      Map.of(parent)
        ..removeWhere((key, _) {
          final k = key.toUpperCase();
          return k.startsWith('YINWEI_') || k.startsWith('FLUTTER_');
        });

  static Future<String?> _processPath(int pid) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").ExecutablePath',
    ]);
    final path = '${result.stdout}'.trim();
    return result.exitCode == 0 && path.isNotEmpty ? path : null;
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
