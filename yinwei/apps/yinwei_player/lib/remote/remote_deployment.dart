import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:yinwei_player/remote/remote_gateway.dart';

class RemoteDeployment {
  RemoteDeployment(
      {this.origin, this.entryOrigin, this.port = 0, this.stateFile});
  final Uri? origin;
  final Uri? entryOrigin;
  final int port;
  final File? stateFile;
  static RemoteDeployment fromEnvironment(Map<String, String> env) {
    final raw = env['YINWEI_REMOTE_PUBLIC_ORIGIN'];
    Uri? origin;
    if (raw != null && raw.isNotEmpty) {
      final parsed = Uri.parse(raw);
      if (parsed.scheme != 'https' ||
          parsed.userInfo.isNotEmpty ||
          parsed.hasQuery ||
          parsed.hasFragment ||
          parsed.port != 443 ||
          !['', '/'].contains(parsed.path) ||
          !RegExp(r'^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$').hasMatch(parsed.host) ||
          parsed.host == 'localhost' ||
          parsed.host.endsWith('.localhost')) {
        throw const FormatException('Invalid Yinwei HTTPS origin');
      }
      origin = Uri.parse('https://${parsed.host}');
    }
    final entry = env['YINWEI_REMOTE_ENTRY_ORIGIN'];
    final entryOrigin = entry == null
        ? null
        : RemoteDeployment.fromEnvironment(
            {'YINWEI_REMOTE_PUBLIC_ORIGIN': entry}).origin;
    final port = int.tryParse(env['YINWEI_REMOTE_PORT'] ?? '0');
    if (port == null || (port != 0 && (port < 1024 || port > 65535))) {
      throw const FormatException('Invalid Yinwei gateway port');
    }
    final state = env['YINWEI_REMOTE_HOST_STATE_FILE'];
    if (state != null &&
        (!File(state).isAbsolute ||
            state.toLowerCase().contains('flutter_assets') ||
            RegExp(r'[\\/]assets[\\/]', caseSensitive: false)
                .hasMatch(state))) {
      throw const FormatException('Host state needs a private absolute path');
    }
    return RemoteDeployment(
        origin: origin,
        entryOrigin: entryOrigin,
        port: port,
        stateFile: state == null ? null : File(state));
  }
}

/// Private attachment record, never served as an application asset. Renewed
/// while the owning player is alive; connector recovery does not restart it.
class RemoteHostRegistration {
  RemoteHostRegistration(this.gateway, this.file);
  final RemoteGateway gateway;
  final File file;
  Timer? _timer;
  Future<void> _writes = Future.value();
  bool _closed = false;
  Future<void> start() async {
    if (_closed) throw StateError('Host registration is closed');
    if (_timer != null) {
      await _write();
      return;
    }
    if (await file.exists()) {
      final old = jsonDecode(await file.readAsString());
      if (old is! Map || old['projectId'] != 'yinwei-remote') {
        throw StateError('Refusing another project host state');
      }
    }
    await _write();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      _writes = _writes.catchError((Object _) {}).then((_) => _write());
      // A failed heartbeat expires at the supervisor; do not interrupt audio.
      _writes.catchError((Object _) {});
    });
  }

  Future<void> _write() async {
    if (_closed) return;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.$pid.tmp');
    await temporary.writeAsString(
        jsonEncode({
          'projectId': 'yinwei-remote',
          'version': 1,
          'processId': pid,
          'hostSessionId': gateway.coordinator.hostSessionId,
          'publicOrigin': gateway.origin.toString(),
          'entryOrigin': gateway.entryOrigin?.toString(),
          'port': gateway.port,
          'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
          'hostToken': gateway.hostToken,
        }),
        flush: true);
    await temporary.rename(file.path);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _writes.catchError((Object _) {});
    if (await file.exists()) {
      final state = jsonDecode(await file.readAsString());
      if (state is Map &&
          state['projectId'] == 'yinwei-remote' &&
          state['hostSessionId'] == gateway.coordinator.hostSessionId) {
        await file.delete();
      }
    }
  }
}
