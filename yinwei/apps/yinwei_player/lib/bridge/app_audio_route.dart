import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/bridge/wet_output_policy.dart';

/// Windows per-app output routing (EarTrumpet / AudioPolicyConfig).
/// Pins the music app to a **silent virtual device** (Steam Streaming
/// Speakers, ToDesk Virtual Audio, VB-Cable) when one exists, so only wet is
/// heard even when the laptop speakers are the wet output. Without one, it
/// falls back to **muted speakers** only when those speakers are
/// not the wet destination. Wet stays on Windows default (or an explicit
/// pick) so Sony `WH-` names do not lock the stream. Nahimic sharing of
/// the default mix is preserved when speakers *are* the wet device.
class AppAudioSplit {
  const AppAudioSplit({
    required this.headphonesName,
    required this.headphonesId,
    required this.speakersName,
    required this.speakersId,
    this.silentSink = false,
  });

  final String headphonesName;
  final String headphonesId;

  /// The dry target: the speakers to mute, or a silent virtual device.
  final String speakersName;
  final String speakersId;

  /// [speakersName] is a virtual device nobody listens to, not real speakers.
  final bool silentSink;
}

/// Line transport to a routing helper. [lines] closes when it ends.
class RouteHelperConnection {
  RouteHelperConnection({
    required this.lines,
    required this.send,
    required this.close,
  });

  final Stream<String> lines;
  final void Function(String line) send;
  final Future<void> Function() close;
}

/// Starts the routing script in `serve` mode and connects to its loopback
/// port with a one-time token.
Future<RouteHelperConnection> connectRouteHelper(String scriptPath) async {
  final random = Random.secure();
  final token =
      List.generate(16, (_) => random.nextInt(256).toRadixString(16)).join();
  final proc = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    scriptPath,
    'serve',
    token,
  ]);
  unawaited(proc.stderr.drain<void>());
  try {
    final portLine = await proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('__YW_PORT__ '))
        .timeout(const Duration(seconds: 15));
    final port = int.parse(portLine.substring('__YW_PORT__ '.length).trim());
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
        timeout: const Duration(seconds: 5));
    socket.encoding = utf8;
    socket.write('$token\n');
    return RouteHelperConnection(
      lines: socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
      send: (line) => socket.write('$line\n'),
      close: () async {
        await socket.close();
        socket.destroy();
      },
    );
  } catch (_) {
    proc.kill();
    rethrow;
  }
}

/// One warm routing helper (`serve` mode of the routing script). The C#
/// helper is compiled and WinRT loaded once, so each command costs tens to a
/// few hundred milliseconds instead of ~2 s for a fresh PowerShell. Commands
/// are serialized. A helper that ends is reconnected on the next command;
/// one that times out twice is abandoned and callers fall back to one-shot
/// runs.
class RouteHelperClient {
  RouteHelperClient(this._connect,
      {this.timeout = const Duration(seconds: 20)});

  final Future<RouteHelperConnection> Function() _connect;
  final Duration timeout;
  RouteHelperConnection? _conn;
  Completer<int>? _pending;
  final List<String> _lines = [];
  Future<void> _queue = Future<void>.value();
  int _timeouts = 0;

  /// True once the helper has timed out twice; use one-shot runs instead.
  bool get abandoned => _timeouts >= 2;

  Future<({int code, List<String> lines})> run(List<String> args) {
    final result = Completer<({int code, List<String> lines})>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await _runUnlocked(args));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<({int code, List<String> lines})> _runUnlocked(
      List<String> args) async {
    if (abandoned) throw StateError('route helper abandoned');
    final conn = _conn ??= await _open();
    _lines.clear();
    final pending = _pending = Completer<int>();
    conn.send(jsonEncode(args));
    try {
      final code = await pending.future.timeout(timeout);
      return (code: code, lines: List<String>.of(_lines));
    } on TimeoutException {
      ++_timeouts;
      _drop();
      rethrow;
    } finally {
      _pending = null;
    }
  }

  Future<RouteHelperConnection> _open() async {
    final conn = await _connect();
    conn.lines.listen(_onLine, onDone: () {
      if (!identical(_conn, conn)) return;
      _conn = null;
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('route helper ended'));
      }
    }, onError: (Object _) {});
    return conn;
  }

  void _onLine(String line) {
    const end = '__YW_END__ ';
    if (line.startsWith(end)) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        pending.complete(int.tryParse(line.substring(end.length).trim()) ?? 9);
      }
    } else {
      _lines.add(line);
    }
  }

  void _drop() {
    final conn = _conn;
    _conn = null;
    if (conn != null) unawaited(conn.close().catchError((Object _) {}));
  }

  /// Ends the helper; it also exits by itself when Yinwei exits.
  Future<void> close() async {
    final conn = _conn;
    _conn = null;
    await conn?.close();
  }
}

class AppAudioRouter {
  AppAudioRouter({RouteHelperClient? helper})
      : _helper = helper,
        _enabled = Platform.isWindows,
        _command = null,
        _recoveryFile = null,
        _log = debugPrint;

  @visibleForTesting
  AppAudioRouter.forTesting({
    required Future<List<String>> Function(List<String>) command,
    required File recoveryFile,
    void Function(String)? log,
  })  : _enabled = true,
        _command = command,
        _recoveryFile = recoveryFile,
        _log = log ?? ((_) {});

  final bool _enabled;
  final Future<List<String>> Function(List<String>)? _command;
  final File? _recoveryFile;
  final void Function(String) _log;
  Future<void>? _recovering;
  AudioRouteRecoveryException? lastRecoveryFailure;

  RouteHelperClient? _helper;
  String? _speakersId;
  bool _unmuteSpeakersOnRestore = false;
  final List<int> _routedPids = [];
  int _routedRootPid = 0;

  bool get isRouted => _routedPids.isNotEmpty;

  /// Root pid last pinned to muted speakers (0 if none).
  int get routedRootPid => _routedRootPid;

  /// Same-app next-track must not re-run the slow PowerShell pin.
  static bool shouldSkipPin({
    required int rootPid,
    required int routedRootPid,
    required bool isRouted,
  }) =>
      isRouted && rootPid > 0 && rootPid == routedRootPid;

  /// [wetName] is the resolved wet device; a silent sink equal to it is
  /// skipped (muting it would silence wet).
  Future<AppAudioSplit?> detectSplit({String wetName = ''}) async {
    if (!_enabled) return null;
    return AppAudioRouter.parseSplit(await _run(['list']), wetName: wetName);
  }

  static AppAudioSplit? parseSplit(List<String> rows, {String wetName = ''}) {
    AppAudioEndpoint? phones;
    AppAudioEndpoint? speakers;
    AppAudioEndpoint? sink;
    for (final line in rows) {
      final p = line.split('|');
      if (p.length < 3) continue;
      final kind = p[0];
      final name = p[1];
      final id = p[2];
      if (kind == 'headphones' && phones == null) {
        phones = AppAudioEndpoint(name, id);
      } else if (kind == 'speakers' && speakers == null) {
        speakers = AppAudioEndpoint(name, id);
      } else if (kind == 'sink' &&
          sink == null &&
          !WetOutputPolicy.sameEndpoint(name, wetName)) {
        sink = AppAudioEndpoint(name, id);
      }
    }
    if (sink != null) {
      return AppAudioSplit(
        headphonesName: phones?.name ?? '',
        headphonesId: phones?.id ?? '',
        speakersName: sink.name,
        speakersId: sink.id,
        silentSink: true,
      );
    }
    if (phones == null || speakers == null) return null;
    if (phones.id == speakers.id) return null;
    return AppAudioSplit(
      headphonesName: phones.name,
      headphonesId: phones.id,
      speakersName: speakers.name,
      speakersId: speakers.id,
    );
  }

  Future<String?> _detectSpeakersId() async {
    final rows = await _run(['list']);
    for (final line in rows) {
      final parts = line.split('|');
      if (parts.length >= 3 && parts[0] == 'speakers') return parts[2];
    }
    return null;
  }

  /// Route [rootPid] and same-exe children to [speakersId]. Remember for restore.
  ///
  /// [keepSpeakerMute] is the source-follow hop: unpin the previous app tree
  /// but do **not** unmute the speaker device (wet stays on headphones).
  Future<bool> routeToSpeakers({
    required int rootPid,
    required String speakersId,
    bool keepSpeakerMute = false,
  }) async {
    if (!_enabled || rootPid <= 0) return false;
    if (shouldSkipPin(
      rootPid: rootPid,
      routedRootPid: _routedRootPid,
      isRouted: isRouted,
    )) {
      return true;
    }
    final preserveUnmute = _unmuteSpeakersOnRestore;
    if (keepSpeakerMute && _speakersId == speakersId) {
      final previous = AudioRouteRecoveryState.parse(await _readDirty());
      for (final pid in _routedPids) {
        final identity =
            previous?.processes.where((p) => p.pid == pid).firstOrNull;
        if (identity == null) throw AudioRouteRecoveryException([pid]);
        await _run(['clear', '$pid', jsonEncode(identity.toJson())]);
      }
      _routedPids.clear();
      _routedRootPid = 0;
    } else {
      await restore();
      keepSpeakerMute = false;
      // Non-routing failures do not block Live, but must not let a new pin
      // overwrite an outstanding speaker restoration or unreadable journal.
      if (await _readDirty() != null) return false;
    }
    if (!keepSpeakerMute) {
      final rows = await _run(['mute-state', speakersId]);
      int? wasMuted;
      for (final line in rows) {
        if (line.startsWith('MUTED_WAS ')) {
          wasMuted = int.tryParse(line.substring('MUTED_WAS '.length));
          break;
        }
      }
      if (wasMuted != 0 && wasMuted != 1) return false;
      _unmuteSpeakersOnRestore = wasMuted == 0;
      _speakersId = speakersId;
    }
    final processes = (await _run(['processes', '$rootPid']))
        .where((line) => line.startsWith('PROCESS '))
        .map((line) =>
            AudioRouteProcessIdentity.parse(jsonDecode(line.substring(8))))
        .whereType<AudioRouteProcessIdentity>()
        .toList();
    if (processes.isEmpty) return false;
    // Journal the exact candidates before apply. The helper only routes these
    // identities, so a crash cannot leave unrecorded same-exe children behind.
    final record = AudioRouteRecoveryState(
      speakersId,
      keepSpeakerMute ? preserveUnmute : _unmuteSpeakersOnRestore,
      rootPid: rootPid,
      routedPids: processes.map((p) => p.pid).toList(),
      processes: processes,
    );
    await _setDirty(true, state: record);
    late final List<String> rows;
    try {
      rows = await _run([
        'apply',
        '$rootPid',
        speakersId,
        jsonEncode(processes.map((p) => p.toJson()).toList())
      ]);
    } catch (_) {
      await restore();
      rethrow;
    }
    final pids = <int>[];
    for (final line in rows) {
      if (line.startsWith('PID ')) {
        pids.add(int.tryParse(line.substring(4).trim()) ?? 0);
      }
    }
    _routedPids
      ..clear()
      ..addAll(pids.where((p) => p > 0));
    _speakersId = speakersId;
    _routedRootPid = _routedPids.isEmpty ? 0 : rootPid;
    if (keepSpeakerMute) {
      _unmuteSpeakersOnRestore = preserveUnmute;
    }
    if (_routedPids.isEmpty) {
      await restore();
      return false;
    }
    await _setDirty(true,
        state: AudioRouteRecoveryState(
          speakersId,
          _unmuteSpeakersOnRestore,
          rootPid: rootPid,
          routedPids: _routedPids,
          processes:
              processes.where((p) => _routedPids.contains(p.pid)).toList(),
        ));
    return _routedPids.isNotEmpty;
  }

  Future<void> restore() async {
    if (!_enabled) return;
    final dirty = await _readDirty();
    if (!isRouted && dirty == null) return;
    await recoverIfDirty();
    _speakersId = null;
    _unmuteSpeakersOnRestore = false;
    _routedRootPid = 0;
    _routedPids.clear();
  }

  /// Undo a route left by a previous process, including its endpoint mute.
  Future<void> recoverIfDirty() =>
      _recovering ??= _recoverDirty().whenComplete(() => _recovering = null);

  /// A failed startup attempt must not latch Live off until the next restart.
  Future<bool> recoverBeforeLive(Future<bool> startupRecovery) async {
    try {
      await startupRecovery;
    } catch (_) {/* Retry current state below. */}
    try {
      await recoverIfDirty();
      return true;
    } on AudioRouteRecoveryException {
      return false;
    }
  }

  Future<AudioRouteProcessIdentity?> _inspect(int pid) async {
    final rows = await _run(['inspect', '$pid']);
    if (rows.contains('MISSING')) return null;
    for (final line in rows) {
      if (line.startsWith('PROCESS ')) {
        final process =
            AudioRouteProcessIdentity.parse(jsonDecode(line.substring(8)));
        if (process != null && process.pid == pid) return process;
      }
    }
    throw const FormatException('Missing process identity');
  }

  Future<void> _recoverDirty() async {
    if (!_enabled) return;
    lastRecoveryFailure = null;
    final dirty = await _readDirty();
    if (dirty == null) return;
    final state = AudioRouteRecoveryState.parse(dirty);
    var stale = 0;
    final blocked = <int>[];
    var pending = false;
    try {
      if (state != null) {
        for (final pid in state.routedPids) {
          final current = await _inspect(pid);
          final expected =
              state.processes.where((p) => p.pid == pid).firstOrNull;
          if (current == null ||
              (expected != null && !expected.matches(current))) {
            stale++;
            continue;
          }
          // Old PID-only journals cannot identify a surviving process safely.
          // A process born after the journal is certainly a reused PID.
          if (expected == null) {
            final modified = await (await _dirtyFile()).lastModified();
            if (current.startedAfter(modified)) {
              stale++;
              continue;
            }
            blocked.add(pid);
            continue;
          }
          try {
            final rows =
                await _run(['clear', '$pid', jsonEncode(expected.toJson())]);
            if (rows.contains('STALE $pid')) stale++;
          } catch (_) {
            // The process can exit between the check and AudioPolicyConfig.
            final after = await _inspect(pid);
            if (after == null || !expected.matches(after)) {
              stale++;
            } else {
              blocked.add(pid);
            }
          }
        }
      } else if (dirty.trim() == '1') {
        // Compatibility with the oldest marker-only journal.
        await _run(['clear-all']);
      }
    } catch (error) {
      pending = true;
      _log('[AudioRoute] recovery pending: ${error.runtimeType}');
    }
    // Always attempt recorded unmute, even if a live PID could not be cleared.
    try {
      final speakerState = state ?? AudioRouteRecoveryState.speakerOnly(dirty);
      if (speakerState != null) {
        if (speakerState.unmute) {
          await _run(['unmute', speakerState.speakersId]);
        }
      } else if (dirty.trim() == '1') {
        final speakersId = await _detectSpeakersId();
        if (speakersId == null) {
          throw StateError('Recorded speaker unavailable');
        }
        await _run(['unmute', speakersId]);
      }
    } catch (error) {
      pending = true;
      _log('[AudioRoute] unmute pending: ${error.runtimeType}');
    }
    if (blocked.isNotEmpty) {
      lastRecoveryFailure = AudioRouteRecoveryException(blocked);
      throw lastRecoveryFailure!;
    }
    if (!pending) {
      try {
        await _setDirty(false);
        _log('[AudioRoute] recovered: $stale stale pids');
      } catch (error) {
        _log('[AudioRoute] journal cleanup pending: ${error.runtimeType}');
      }
    }
  }

  /// Start the warm helper ahead of time so the first Live Transfer does not
  /// pay PowerShell start-up and C# compilation.
  Future<void> warmUp() async {
    if (!_enabled) return;
    try {
      await _helperClient().run(['ping']);
    } catch (error) {
      // _run falls back to one-shot PowerShell when the helper is unusable.
    }
  }

  RouteHelperClient _helperClient() => _helper ??=
      RouteHelperClient(() async => connectRouteHelper(await _ensureScript()));

  Future<List<String>> _run(List<String> args) async {
    if (_command != null) return _command(args);
    final helper = _helperClient();
    if (!helper.abandoned) {
      ({int code, List<String> lines})? result;
      try {
        result = await helper.run(args);
      } catch (error) {
        // Helper unavailable or timed out: run this command one-shot below.
      }
      if (result != null) {
        if (result.code != 0) {
          throw ProcessException('powershell.exe', args, '', result.code);
        }
        return result.lines.where((line) => line.trim().isNotEmpty).toList();
      }
    }
    return _runOnce(args);
  }

  Future<List<String>> _runOnce(List<String> args) async {
    final script = await _ensureScript();
    final proc = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        ...args,
      ],
    );
    if (proc.exitCode != 0) {
      throw ProcessException('powershell.exe', args,
          (proc.stderr as String? ?? '').trim(), proc.exitCode);
    }
    final out = (proc.stdout as String? ?? '').trim();
    if (out.isEmpty) return const [];
    return const LineSplitter().convert(out);
  }

  Future<String> _ensureScript() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}\\yinwei_app_audio_route.ps1');
    await file.writeAsString(_kScript, flush: true);
    return file.path;
  }

  Future<File> _dirtyFile() async {
    if (_recoveryFile != null) return _recoveryFile;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}\\yinwei_audio_route.dirty');
  }

  Future<String?> _readDirty() async {
    try {
      final file = await _dirtyFile();
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _setDirty(bool dirty, {AudioRouteRecoveryState? state}) async {
    final file = await _dirtyFile();
    if (dirty) {
      if (state == null) throw StateError('Missing audio route recovery state');
      await file.writeAsString(state.encode(), flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  }
}

class AudioRouteRecoveryException implements Exception {
  AudioRouteRecoveryException(Iterable<int> pids)
      : pids = List<int>.unmodifiable(pids);
  final List<int> pids;
  @override
  String toString() =>
      'Cannot safely restore audio for running PID(s): ${pids.join(', ')}';
}

class AudioRouteProcessIdentity {
  const AudioRouteProcessIdentity(this.pid, this.name, this.startTime);
  final int pid;
  final String name;

  /// UTC Windows ticks, serialized as a string without JSON number rounding.
  final String startTime;

  Map<String, Object> toJson() =>
      {'pid': pid, 'name': name, 'startTime': startTime};
  bool matches(AudioRouteProcessIdentity other) =>
      pid == other.pid &&
      name.toLowerCase() == other.name.toLowerCase() &&
      startTime == other.startTime;
  bool startedAfter(DateTime time) =>
      int.parse(startTime) >
      time.toUtc().microsecondsSinceEpoch * 10 + 621355968000000000;

  static AudioRouteProcessIdentity? parse(Object? value) {
    if (value is! Map ||
        value['pid'] is! int ||
        (value['pid'] as int) <= 0 ||
        value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        value['startTime'] is! String) {
      return null;
    }
    final time = value['startTime'] as String;
    if (!RegExp(r'^[0-9]{1,19}$').hasMatch(time) ||
        (int.tryParse(time) ?? 0) <= 0) {
      return null;
    }
    return AudioRouteProcessIdentity(
        value['pid'] as int, value['name'] as String, time);
  }
}

class AudioRouteRecoveryState {
  const AudioRouteRecoveryState(this.speakersId, this.unmute,
      {required this.rootPid,
      required this.routedPids,
      this.processes = const []});

  final String speakersId;
  final bool unmute;
  final int rootPid;
  final List<int> routedPids;
  final List<AudioRouteProcessIdentity> processes;

  String encode() => jsonEncode({
        'speakersId': speakersId,
        'unmute': unmute,
        'rootPid': rootPid,
        'routedPids': routedPids,
        'processes': processes.map((p) => p.toJson()).toList(),
      });

  /// Salvage a valid speaker obligation even when other fields are damaged.
  static AudioRouteRecoveryState? speakerOnly(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map &&
          value['speakersId'] is String &&
          (value['speakersId'] as String).isNotEmpty &&
          value['unmute'] is bool) {
        return AudioRouteRecoveryState(
            value['speakersId'] as String, value['unmute'] as bool,
            rootPid: 0, routedPids: const []);
      }
    } catch (_) {/* No trustworthy speaker information. */}
    return null;
  }

  static AudioRouteRecoveryState? parse(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['speakersId'] is! String ||
          (value['speakersId'] as String).isEmpty ||
          value['unmute'] is! bool ||
          value['rootPid'] is! int ||
          value['routedPids'] is! List) {
        return null;
      }
      final rawPids = value['routedPids'] as List;
      if (rawPids.length > 1024 ||
          rawPids.any((pid) => pid is! int || pid <= 0)) {
        return null;
      }
      final pids = rawPids.cast<int>().toSet().toList();
      final processes = <AudioRouteProcessIdentity>[];
      if (value['processes'] is List) {
        for (final entry in value['processes'] as List) {
          final process = AudioRouteProcessIdentity.parse(entry);
          if (process != null && pids.contains(process.pid)) {
            processes.add(process);
          }
        }
      }
      return AudioRouteRecoveryState(
        value['speakersId'] as String,
        value['unmute'] as bool,
        rootPid: value['rootPid'] as int,
        routedPids: pids,
        processes: processes,
      );
    } catch (_) {
      return null;
    }
  }
}

class AppAudioEndpoint {
  AppAudioEndpoint(this.name, this.id);
  final String name;
  final String id;
}

const _kScript = r'''
param(
  [Parameter(Position=0)][string]$Action,
  [Parameter(Position=1)][string]$Arg1,
  [Parameter(Position=2)][string]$Arg2,
  [Parameter(Position=3)][string]$Arg3,
  [Parameter(Position=4)][string]$Arg4
)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class YinweiPolicy {
  [ComImport]
  [Guid("ab3d4648-e242-459f-b02f-541c70306324")]
  [InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
  interface IFactory21 {
    int i00(); int i01(); int i02(); int i03(); int i04();
    int i05(); int i06(); int i07(); int i08(); int i09();
    int i10(); int i11(); int i12(); int i13(); int i14();
    int i15(); int i16(); int i17(); int i18();
    [PreserveSig] int SetPersistedDefaultAudioEndpoint(uint pid, int flow, int role, IntPtr deviceId);
    [PreserveSig] int GetPersistedDefaultAudioEndpoint(uint pid, int flow, int role, out IntPtr deviceId);
    [PreserveSig] int ClearAllPersistedApplicationDefaultEndpoints();
  }
  [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr activatableClassId, ref Guid iid, out IntPtr factory);
  [DllImport("combase.dll")] static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string s, int len, out IntPtr h);
  [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr h);
  static IFactory21 Fac() {
    IntPtr hclass; string cls = "Windows.Media.Internal.AudioPolicyConfig";
    WindowsCreateString(cls, cls.Length, out hclass);
    Guid iid = new Guid("ab3d4648-e242-459f-b02f-541c70306324");
    IntPtr unk; RoGetActivationFactory(hclass, ref iid, out unk);
    WindowsDeleteString(hclass);
    return (IFactory21)Marshal.GetObjectForIUnknown(unk);
  }
  public static int Set(uint pid, string deviceId) {
    var fac = Fac();
    IntPtr hdev; WindowsCreateString(deviceId, deviceId.Length, out hdev);
    int hr = 0;
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 0, hdev);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 1, hdev);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 2, hdev);
    WindowsDeleteString(hdev);
    return hr;
  }

  public static int Clear(uint pid) {
    var fac = Fac();
    int hr = 0;
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 0, IntPtr.Zero);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 1, IntPtr.Zero);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 2, IntPtr.Zero);
    return hr;
  }

  static string ToMmId(string id) {
    if (string.IsNullOrEmpty(id)) return id;
    int start = id.IndexOf("{0.0.0.");
    if (start < 0) return id;
    int end = id.IndexOf("}#", start);
    if (end < 0) return id.Substring(start);
    return id.Substring(start, end - start + 1);
  }

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints();
    int GetDefaultAudioEndpoint();
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
  }
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int a0(); int a1(); int a2(); int a3(); int a4(); int a5(); int a6(); int a7(); int a8(); int a9(); int a10();
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, IntPtr ctx);
    [PreserveSig] int GetMute(out int pbMute);
  }
  [DllImport("ole32.dll")]
  static extern int CoCreateInstance(ref Guid clsid, IntPtr unk, int ctx, ref Guid iid, out IMMDeviceEnumerator pp);

  static IAudioEndpointVolume Volume(string id) {
    var clsid = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
    var iidEn = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
    IMMDeviceEnumerator en;
    if (CoCreateInstance(ref clsid, IntPtr.Zero, 23, ref iidEn, out en) != 0) return null;
    IMMDevice dev;
    if (en.GetDevice(ToMmId(id), out dev) != 0 || dev == null) return null;
    var iidVol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
    IntPtr p;
    if (dev.Activate(ref iidVol, 23, IntPtr.Zero, out p) != 0 || p == IntPtr.Zero) return null;
    return (IAudioEndpointVolume)Marshal.GetObjectForIUnknown(p);
  }

  public static int GetMuted(string id) {
    var vol = Volume(id);
    if (vol == null) return -1;
    int m; vol.GetMute(out m); return m;
  }

  public static int SetMuted(string id, bool mute) {
    var vol = Volume(id);
    if (vol == null) return -1;
    return vol.SetMute(mute, IntPtr.Zero);
  }

  public static int ClearAll() {
    var fac = Fac();
    return fac.ClearAllPersistedApplicationDefaultEndpoints();
  }
}
'@
Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue | Out-Null

function Get-RenderDevices {
  $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
  }
  [void][Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
  $aqs = 'System.Devices.InterfaceClassGuid:="{e6327cad-dcec-4949-ae8a-991e976a79d2}" AND System.Devices.InterfaceEnabled:=System.StructuredQueryType.Boolean#True'
  $op = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($aqs)
  Await $op ([Windows.Devices.Enumeration.DeviceInformationCollection])
}

function Classify([string]$name) {
  $n = $name.ToLowerInvariant()
  # Keep in sync with WetOutputPolicy.classify (wet_output_policy.dart).
  # Nahimic / A-Volute Sound Sharing must not be ignored or muted as "virtual".
  if ($n -match 'nahimic|a-volute|avolute|sound sharing') { return 'nahimic' }
  if ($n -match 'todesk|steam|virtual|cable|vb-audio|nvidia|oculus|meta|vac ') { return 'ignore' }
  if ($n -match '耳机|headphone|headset|wh-|airpods|buds|earbuds') { return 'headphones' }
  if ($n -match '扬声器|speakers?') { return 'speakers' }
  return 'other'
}

function Get-RouteProcess([int]$processId) {
  try {
    $process = [System.Diagnostics.Process]::GetProcessById($processId)
  } catch [System.ArgumentException] { return $null }
  # Hold the native process handle throughout the identity check and command.
  # A recycled PID must never redirect cleanup to a different process.
  try {
    [void]$process.Handle
    if ($process.HasExited) { $process.Dispose(); return $null }
    [void]$process.StartTime
    return $process
  } catch {
    $exited = $false
    try { $exited = $process.HasExited } catch {}
    $process.Dispose()
    if ($exited) { return $null }
    throw
  }
}

function Route-Identity($process) {
  [pscustomobject]@{
    pid = $process.Id
    name = $process.ProcessName
    startTime = $process.StartTime.ToUniversalTime().Ticks.ToString([System.Globalization.CultureInfo]::InvariantCulture)
  }
}

function Same-RouteProcess($process, $expected) {
  $actual = Route-Identity $process
  return ($actual.pid -eq $expected.pid -and $actual.name -ieq $expected.name -and $actual.startTime -ceq $expected.startTime)
}

function Invoke-YinweiAction([string]$Action, [string]$Arg1, [string]$Arg2, [string]$Arg3, [string]$Arg4) {
  if ($Action -eq 'ping') { Write-Output 'PONG'; $script:YwCode = 0; return }
  if ($Action -eq 'list') {
    $col = Get-RenderDevices
    $phone = $null; $spk = $null; $nah = $null
    foreach ($d in $col) {
      $k = Classify $d.Name
      if ($k -eq 'headphones' -and -not $phone) { $phone = $d }
      if ($k -eq 'nahimic' -and -not $nah) { $nah = $d }
      if ($k -eq 'speakers') {
        if (-not $spk) { $spk = $d }
        elseif ($d.Name -match 'Realtek|Realtek') { $spk = $d }
      }
    }
    if ($phone) { Write-Output ("headphones|" + $phone.Name + "|" + $phone.Id) }
    if ($spk) { Write-Output ("speakers|" + $spk.Name + "|" + $spk.Id) }
    if ($nah) { Write-Output ("nahimic|" + $nah.Name + "|" + $nah.Id) }
    # Silent virtual outputs nobody listens to, preferred first. Never a
    # microphone-loopback endpoint.
    $sinks = @()
    foreach ($d in $col) {
      $n = $d.Name.ToLowerInvariant()
      if ($n -match 'microphone|麦克风') { continue }
      $rank = 0
      if ($n -match 'steam streaming speakers') { $rank = 1 }
      elseif ($n -match 'todesk virtual audio') { $rank = 2 }
      elseif ($n -match 'cable input|vb-audio') { $rank = 3 }
      if ($rank -gt 0) { $sinks += [pscustomobject]@{ Rank = $rank; Device = $d } }
    }
    foreach ($s in ($sinks | Sort-Object Rank)) {
      Write-Output ("sink|" + $s.Device.Name + "|" + $s.Device.Id)
    }
    $script:YwCode = 0; return
  }

  function Pids-ForRoot([int]$root) {
    $rootProc = Get-CimInstance Win32_Process -Filter "ProcessId=$root" -ErrorAction SilentlyContinue
    if (-not $rootProc) { return @($root) }
    $exe = $rootProc.Name
    @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq $exe } | ForEach-Object { [int]$_.ProcessId })
  }

  if ($Action -eq 'inspect' -or $Action -eq 'processes') {
    $targets = @([int]$Arg1)
    if ($Action -eq 'processes') { $targets = @(Pids-ForRoot ([int]$Arg1)) }
    foreach ($p in $targets) {
      $process = Get-RouteProcess $p
      if ($null -eq $process) {
        if ($Action -eq 'inspect') { Write-Output 'MISSING' }
        continue
      }
      try { Write-Output ('PROCESS ' + ((Route-Identity $process) | ConvertTo-Json -Compress)) }
      finally { $process.Dispose() }
    }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'apply') {
    $root = [int]$Arg1
    $dev = [string]$Arg2
    $routed = 0
    $applied = @()
    $candidates = @()
    if ($Arg3) { $candidates = @($Arg3 | ConvertFrom-Json) }
    foreach ($candidate in $candidates) {
      $p = [int]$candidate.pid
      $process = Get-RouteProcess $p
      if ($null -eq $process) { continue }
      try {
        if (-not (Same-RouteProcess $process $candidate)) { continue }
        $hr = [YinweiPolicy]::Set([uint32]$p, $dev)
        if ($hr -eq 0) { Write-Output "PID $p"; $routed++; $applied += $p }
      } finally { $process.Dispose() }
    }
    if ($routed -eq 0) { $script:YwCode = 2; return }
    $hr = [YinweiPolicy]::SetMuted($dev, $true)
    # SetMute returns S_FALSE (1) when the device already had that state;
    # only negative HRESULTs (and -1: device missing) are failures.
    if ($hr -lt 0) {
      foreach ($p in $applied) {
        $expected = $candidates | Where-Object { [int]$_.pid -eq $p } | Select-Object -First 1
        Invoke-YinweiAction 'clear' "$p" ($expected | ConvertTo-Json -Compress) '' ''
      }
      $script:YwCode = 3; return
    }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'mute-state') {
    $was = [YinweiPolicy]::GetMuted([string]$Arg1)
    Write-Output "MUTED_WAS $was"
    if ($was -lt 0) { $script:YwCode = 4; return }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'clear') {
    $bad = 0
    foreach ($textPid in $Arg1.Split(',')) {
      $parsedPid = 0
      if (-not [int]::TryParse($textPid, [ref]$parsedPid) -or $parsedPid -le 0) { continue }
      $process = Get-RouteProcess $parsedPid
      if ($null -eq $process) { Write-Output "STALE $parsedPid"; continue }
      try {
        if ($Arg2 -and -not (Same-RouteProcess $process ($Arg2 | ConvertFrom-Json))) {
          Write-Output "STALE $parsedPid"; continue
        }
        try {
          $hr = [YinweiPolicy]::Clear([uint32]$parsedPid)
          if ($hr -lt 0) {
            if ($process.HasExited) { Write-Output "STALE $parsedPid" } else { $bad++ }
          }
        } catch {
          if ($process.HasExited) { Write-Output "STALE $parsedPid" } else { $bad++ }
        }
      } finally { $process.Dispose() }
    }
    if ($bad -gt 0) { $script:YwCode = 5; return }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'clear-all') {
    $hr = [YinweiPolicy]::ClearAll()
    Write-Output ("CLEAR_HR $hr")
    if ($hr -ne 0) { $script:YwCode = 5; return }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'unmute') {
    $hr = [YinweiPolicy]::SetMuted([string]$Arg1, $false)
    # Already unmuted returns S_FALSE (1), which is success, not an error.
    if ($hr -lt 0) { $script:YwCode = 6; return }
    $script:YwCode = 0; return
  }

  if ($Action -eq 'restore') {
    [void][YinweiPolicy]::ClearAll()
    $dev = [string]$Arg1
    $ids = @()
    if ($Arg2) { $ids = $Arg2.Split(',') | ForEach-Object { [int]$_ } }
    foreach ($p in $ids) {
      if ($p -gt 0) { [void][YinweiPolicy]::Set([uint32]$p, $dev) }
    }
    if ($Arg3 -eq '1' -and $Arg4) {
      [void][YinweiPolicy]::SetMuted($Arg4, $false)
    }
    $script:YwCode = 0; return
  }
}

# serve: compile the helper and load WinRT once, then answer one JSON array
# of arguments per line. Each answer ends with "__YW_END__ <code>".
# Commands arrive over a loopback-only socket, not stdin: PowerShell does not
# reliably read stdin written by a Dart parent. The port is printed on stdout;
# the client must send $Arg1 (a one-time token) first. The helper exits when
# the connection closes (including when Yinwei exits) or if no client
# connects within 15 s.
if ($Action -eq 'serve') {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  [Console]::Out.WriteLine('__YW_PORT__ ' + $listener.LocalEndpoint.Port)
  [Console]::Out.Flush()
  $accept = $listener.AcceptTcpClientAsync()
  if (-not $accept.Wait(15000)) { $listener.Stop(); exit 7 }
  $client = $accept.Result
  $listener.Stop()
  $stream = $client.GetStream()
  $reader = New-Object System.IO.StreamReader($stream, $utf8)
  $writer = New-Object System.IO.StreamWriter($stream, $utf8)
  $writer.NewLine = "`n"
  if ([string]::IsNullOrEmpty($Arg1) -or $reader.ReadLine() -ne $Arg1) { $client.Close(); exit 8 }
  while ($true) {
    $line = $null
    try { $line = $reader.ReadLine() } catch { break }
    if ($null -eq $line) { break }
    $script:YwCode = 9
    $replies = @()
    try {
      # PowerShell 5.1 emits a JSON array as one object: unroll it.
      $req = @(($line | ConvertFrom-Json) | ForEach-Object { [string]$_ }) + @('', '', '', '', '')
      $script:YwCode = 0
      $replies = @(Invoke-YinweiAction ([string]$req[0]) ([string]$req[1]) ([string]$req[2]) ([string]$req[3]) ([string]$req[4]))
    } catch { $script:YwCode = 9 }
    try {
      foreach ($reply in $replies) { $writer.WriteLine([string]$reply) }
      $writer.WriteLine('__YW_END__ ' + $script:YwCode)
      $writer.Flush()
    } catch { break }
  }
  $client.Close()
  exit 0
}

$script:YwCode = 0
Invoke-YinweiAction $Action $Arg1 $Arg2 $Arg3 $Arg4
exit $script:YwCode
''';
