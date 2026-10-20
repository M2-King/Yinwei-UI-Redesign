import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'private_pair_store.dart';

/// A request the laptop refused, with its error code (e.g. `control_lost`).
/// Never carries credentials or response bodies.
class RemoteApiException implements Exception {
  const RemoteApiException(this.path, this.statusCode, this.code);
  final String path;
  final int statusCode;
  final String code;
  @override
  String toString() => 'RemoteApiException($statusCode, $code)';
}

/// The owner's requests from a native app, the same ones the iPad web page
/// makes: sign-in, session, control lease, commands and ticketed WebSockets.
/// The password is only sent once; cookies and CSRF stay in memory.
class RemoteOwnerClient {
  RemoteOwnerClient({required this.origin, bool allowLoopbackForTests = false})
      : privatePair = null {
    final loopback = allowLoopbackForTests &&
        origin.scheme == 'http' &&
        origin.host == '127.0.0.1';
    if ((!loopback && origin.scheme != 'https') ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw ArgumentError('An exact HTTPS Yinwei origin is required');
    }
  }

  /// HTTP is permitted only for the exact paired WireGuard endpoint. The
  /// public entry resolver and normal HTTPS constructor remain unchanged.
  RemoteOwnerClient.privateRoute(PrivatePair pair,
      {bool allowLoopbackForTests = false})
      : origin = pair.origin,
        privatePair = pair {
    if (PrivatePair.parseOrigin(origin.toString(),
            loopbackForTesting: allowLoopbackForTests) ==
        null) {
      throw ArgumentError('Invalid paired WireGuard endpoint');
    }
    _http.connectionTimeout = const Duration(seconds: 2);
  }

  final Uri origin;
  final PrivatePair? privatePair;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final _cookies = <String, String>{};
  final _random = Random.secure();
  String? _csrf;
  bool _closed = false;

  bool get signedIn => _csrf != null && !_closed;

  String get _originHeader => origin.toString().replaceAll(RegExp(r'/$'), '');
  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? body,
      String? csrf,
      PrivatePair? pairProof}) async {
    if (_closed) throw StateError('Client closed');
    final req = await _http
        .openUrl(body == null ? 'GET' : 'POST', origin.resolve(path))
        .timeout(const Duration(seconds: 5));
    req.followRedirects = false;
    req.headers.set('Origin', _originHeader);
    final pair = privatePair ?? pairProof;
    if (pair != null) {
      req.headers.set('X-Yinwei-Pair-Id', pair.id);
      req.headers.set('X-Yinwei-Pair-Key', pair.key);
    }
    if (_cookies.isNotEmpty) req.headers.set('Cookie', _cookieHeader);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      final token = csrf ?? _csrf;
      if (token != null) req.headers.set('X-CSRF-Token', token);
      req.write(jsonEncode(body));
    }
    // Remote commands wait for the laptop (Live start can take ~15 s).
    final deadline = Duration(
        seconds:
            path == '/remote/api/auth/signin' || path == '/remote/api/commands'
                ? 60
                : privatePair != null
                    ? 2
                    : 15);
    final response = await req.close().timeout(deadline);
    final bytes = <int>[];
    await for (final chunk in response.timeout(deadline)) {
      bytes.addAll(chunk);
      if (bytes.length > 1 << 20) {
        throw const FormatException('response_too_large');
      }
    }
    Object? value;
    if (path != '/remote/signin') {
      try {
        value = jsonDecode(utf8.decode(bytes));
      } catch (_) {}
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 401) _csrf = null;
      final code = value is Map && value['error'] is String
          ? value['error'] as String
          : 'request_failed';
      throw RemoteApiException(path, response.statusCode, code);
    }
    for (final cookie in response.cookies) {
      if (![
            '__Host-yinwei',
            '__Host-yinwei_prelogin',
            'yinwei_local',
            'yinwei_prelogin',
            'yinwei_private'
          ].contains(cookie.name) ||
          cookie.value.length > 4096) {
        continue;
      }
      if (cookie.maxAge == 0) {
        _cookies.remove(cookie.name);
      } else {
        _cookies[cookie.name] = cookie.value;
      }
    }
    // The sign-in page is HTML; only its cookie is needed here.
    if (path == '/remote/signin') return const {};
    if (value is! Map<String, dynamic>) {
      throw const FormatException('invalid_response');
    }
    return value;
  }

  /// Signs in and returns the session (with the first snapshot).
  Future<Map<String, dynamic>> signIn(String username, String password) async {
    if (privatePair != null) throw StateError('No password on private routes');
    _cookies.clear();
    _csrf = null;
    await _request('/remote/signin');
    final nonce =
        _cookies['__Host-yinwei_prelogin'] ?? _cookies['yinwei_prelogin'];
    if (nonce == null) throw const FormatException('prelogin_missing');
    await _request('/remote/api/auth/signin',
        csrf: nonce, body: {'username': username, 'password': password});
    return session();
  }

  Future<Map<String, dynamic>> pairingTicket() =>
      _request('/remote/api/private/pair-ticket', body: {});

  Future<Map<String, dynamic>> resumePair(PrivatePair pair,
      {String? ticket}) async {
    if (ticket != null && privatePair == null) {
      throw StateError('Enrollment completes only on the private route');
    }
    final value = await _request(
        '/remote/api/private/${ticket == null ? 'resume' : 'pair'}',
        body: {if (ticket != null) 'ticket': ticket},
        pairProof: pair);
    if (value['hostId'] != pair.hostId ||
        value['csrf'] is! String ||
        value['snapshot'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_pairing_host');
    }
    _csrf = value['csrf'] as String;
    return value;
  }

  Future<Map<String, dynamic>> session() async {
    final value = await _request('/remote/api/session');
    if (value['csrf'] is! String || value['snapshot'] is! Map) {
      throw const FormatException('invalid_session');
    }
    _csrf = value['csrf'] as String;
    return value;
  }

  /// [auto]: re-taking control this device had; the laptop refuses it with
  /// `control_taken` once someone at the laptop took over.
  Future<String> lease({bool auto = false}) async {
    final value = await _request('/remote/api/control/lease',
        body: auto ? {'auto': true} : {});
    final id = value['controlLeaseId'];
    if (id is! String) throw const FormatException('invalid_lease');
    return id;
  }

  Future<Map<String, dynamic>> command(
          Map<String, dynamic> snapshot, String lease, String type,
          [Map<String, dynamic> payload = const {}]) =>
      sendCommand(commandEnvelope(snapshot, lease, type, payload));

  Map<String, dynamic> commandEnvelope(Map<String, dynamic> snapshot,
          String lease, String type, Map<String, dynamic> payload) =>
      {
        'protocolVersion': 1,
        'commandId': _commandId(),
        'hostSessionId': snapshot['hostSessionId'],
        'controlLeaseId': lease,
        'expectedStateVersion': snapshot['stateVersion'],
        'expectedSceneRevision': snapshot['sceneRevision'],
        'type': type,
        'payload': payload,
      };

  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> envelope) =>
      _request('/remote/api/commands', body: envelope);

  String _commandId() {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return 'ipad_${List.generate(24, (_) => alphabet[_random.nextInt(alphabet.length)]).join()}';
  }

  /// Opens `/remote/ws/<purpose>` (`events` or `audio`) with a one-time
  /// ticket and sends it; the laptop answers with its first message.
  /// [hello] adds fields to the first message (the audio socket's quality).
  Future<WebSocket> openSocket(String purpose,
      {Map<String, Object?>? hello}) async {
    final grant =
        await _request('/remote/api/ws-ticket', body: {'purpose': purpose});
    final ticket = grant['ticket'];
    if (ticket is! String) throw const FormatException('invalid_ticket');
    var abandoned = false;
    final opening = WebSocket.connect(
            origin
                .replace(
                    scheme: origin.scheme == 'https' ? 'wss' : 'ws',
                    path: '/remote/ws/$purpose')
                .toString(),
            headers: {
              'Origin': _originHeader,
              'Cookie': _cookieHeader,
              if (privatePair != null) ...{
                'X-Yinwei-Pair-Id': privatePair!.id,
                'X-Yinwei-Pair-Key': privatePair!.key,
              }
            },
            compression: CompressionOptions.compressionOff)
        .then((socket) {
      if (abandoned || _closed) {
        unawaited(socket.close());
        throw StateError('Connection cancelled');
      }
      return socket;
    });
    final WebSocket socket;
    try {
      socket =
          await opening.timeout(Duration(seconds: privatePair == null ? 8 : 2));
    } catch (_) {
      // A late handshake must not leave an orphan socket alive.
      abandoned = true;
      rethrow;
    }
    socket.pingInterval = const Duration(seconds: 10);
    socket.add(jsonEncode({...?hello, 'ticket': ticket}));
    return socket;
  }

  Future<void> signOut() async {
    try {
      if (_csrf != null) {
        await _request('/remote/api/auth/signout', body: {});
      }
    } finally {
      _csrf = null;
      _cookies.clear();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _csrf = null;
    _cookies.clear();
    _http.close(force: true);
  }
}
