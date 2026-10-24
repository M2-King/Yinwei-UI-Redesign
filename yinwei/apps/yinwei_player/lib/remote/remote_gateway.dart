import 'listen_tap_trace.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_guest.dart';
import 'package:yinwei_player/remote/listen_stream_source.dart';
import 'package:yinwei_player/remote/listen_sender_pacer.dart';
import 'package:yinwei_player/remote/listen_udp_sender.dart';
import 'package:yinwei_player/remote/native_output_tap.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/private_route.dart';
import 'package:yinwei_player/remote/remote_transform.dart';
import 'package:yinwei_player/remote/remote_transform_socket.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';

typedef RemoteAssetLoader = Future<Uint8List> Function(String asset);

class RemoteGateway {
  /// Unacknowledged browser-listening packets allowed in flight.
  static const audioCredit = 64;

  RemoteGateway(
      {required this.auth,
      required this.coordinator,
      required this.loadAsset,
      this.entryOrigin,
      this.allowOriginRotation = false,
      this.audioTap,
      this.liveAudioTap,
      bool? allowArrayFileAudio,
      this.transformAdapter,
      this.createOpusEncoder,
      this.privateRoute,
      this.guests,
      bool? listenUdp,
      int? listenUdpPort})
      : allowArrayFileAudio = allowArrayFileAudio ??
            Platform.environment['YINWEI_ARRAY_FILE_AUDIO_VERIFIED'] == '1',
        listenUdp =
            listenUdp ?? Platform.environment['YINWEI_LISTEN_UDP'] == '1',
        listenUdpPort = listenUdpPort ??
            int.tryParse(Platform.environment['YINWEI_LISTEN_UDP_PORT'] ?? '') ??
            8444;

  /// Listen audio over UDP on the private route (off by default;
  /// docs/IMPLEMENTATION_LISTEN_UDP_AUDIO.md). The WebSocket stays the backup.
  final bool listenUdp;
  final int listenUdpPort;
  ListenUdpSender? _udp;
  Future<void>? _udpBinding;
  bool _audioViaUdp = false;
  int _audioLastSent = 0;

  /// Binds the UDP sender to the private route's Tailscale address once.
  void _bindUdp() {
    final route = privateRoute;
    if (!listenUdp || route == null || _udp != null || _udpBinding != null) {
      return;
    }
    _udpBinding = ListenUdpSender.bind(route.config.address, listenUdpPort)
        .then((sender) => _udp = sender)
        .whenComplete(() => _udpBinding = null);
  }

  /// Audio goes back to the WebSocket (UDP failed or the session ended).
  void _audioToWebSocket(WebSocket socket, {bool tell = false}) {
    if (!_audioViaUdp) return;
    _audioViaUdp = false;
    if (tell) {
      try {
        socket.add(jsonEncode({'type': 'transport', 'transport': 'wss'}));
      } catch (_) {}
    }
  }

  /// Isolated opt-in: the pinned DLL's file tap must first be checked using
  /// tool/remote/check_array_file_tap.py. Default keeps the existing safety gate.
  final bool allowArrayFileAudio;

  /// The Listen stream's Opus encoder; null keeps every stream uncompressed.
  final ListenOpusEncoder? Function()? createOpusEncoder;

  /// Friend accounts (Option L). Null unless YINWEI_GUEST_ENABLED=1; then
  /// every `/remote/guest/*` request returns 404.
  final GuestService? guests;
  final RemoteTransformAdapter? transformAdapter;
  WebSocket? _transformSocket;
  RemoteTransformSocket? _transformStream;
  RemoteSession? _transformSession;
  bool _transformUpgradePending = false;
  int _transformEpoch = Random.secure().nextInt(0x7fffffff) + 1;
  final bool allowOriginRotation;
  final RemoteOutputSource? audioTap;
  final RemoteOutputSource? liveAudioTap;
  final Uri? entryOrigin;
  final RemoteAuth auth;
  final PrivateRouteHost? privateRoute;
  final _privateSockets = <WebSocket, ({String address, String pairId})>{};
  final _checkingPrivate = <WebSocket>{};
  Timer? _privateChecks;
  final String hostToken = remoteSecret(32);
  final AppSessionCoordinator coordinator;
  final RemoteAssetLoader loadAsset;
  HttpServer? _server;
  Uri? _origin;
  bool _secure = false;
  int _originEpoch = 0;
  int _active = 0;
  int _privateActive = 0;
  int _upgrades = 0;
  final _prelogin = <String, DateTime>{};
  final _sockets = <WebSocket, RemoteSession>{};
  final _connections = <WebSocket>{};
  final _pendingAck = <WebSocket, int>{};
  final _sentAt = <WebSocket, DateTime>{};
  int _eventSequence = 0;
  WebSocket? _audioSocket;
  RemoteSession? _audioSession;
  RemoteOutputSource? _activeAudioTap;
  // Set when the client chose a quality (the iPad app); browsers read the tap.
  ListenStreamSource? _audioStream;
  bool _activeAudioIsLive = false;
  final _audioOutstanding = <int, DateTime>{};
  int _audioLastAck = 0;
  RemoteOutputSource? get _selectedAudioTap =>
      coordinator.remoteTransformRunning
          ? null
          : coordinator.liveRunning()
              ? (coordinator.liveReady ? liveAudioTap : null)
              : (coordinator.controller.array.enabled && !allowArrayFileAudio
                  ? null
                  : audioTap);
  Timer? _audioTimer;
  final _audioPacer = ListenSenderPacer();
  final _audioPaceClock = Stopwatch()..start();
  Uint8List? _pacedPacket;
  final _requests = <String, List<DateTime>>{};
  final _captureProbeReports = <String, List<Map<String, dynamic>>>{};
  Timer? _events;
  Uri get origin => _origin!;
  int get port => _server!.port;
  String get _cookieName => _secure ? '__Host-yinwei' : 'yinwei_local';
  String get _preloginCookieName =>
      _secure ? '__Host-yinwei_prelogin' : 'yinwei_prelogin';

  Future<void> start({int port = 0, Uri? publicOrigin}) async {
    if (_server != null) throw StateError('Gateway already started');
    if (publicOrigin != null &&
        (publicOrigin.scheme != 'https' ||
            publicOrigin.host.isEmpty ||
            publicOrigin.userInfo.isNotEmpty ||
            publicOrigin.hasQuery ||
            publicOrigin.hasFragment ||
            publicOrigin.path.isNotEmpty)) {
      throw ArgumentError('Public origin must be an exact HTTPS origin');
    }
    if (allowOriginRotation &&
        (publicOrigin == null || !_quickOrigin(publicOrigin))) {
      throw ArgumentError('Origin rotation requires a temporary HTTPS tunnel');
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port,
        shared: false);
    _origin = publicOrigin ?? Uri.parse('http://127.0.0.1:${_server!.port}');
    _secure = publicOrigin != null;
    coordinator.browserAudioAvailable = audioTap != null;
    coordinator.browserLiveAudioAvailable = liveAudioTap != null;
    _server!.listen((request) => unawaited(_handle(request)),
        onError: (Object _) {});
    if (privateRoute != null) {
      try {
        await privateRoute!.start((request) => _handle(request, private: true));
        _bindUdp();
        _privateChecks = Timer.periodic(const Duration(seconds: 2), (_) {
          for (final entry in _privateSockets.entries.toList()) {
            if (!_checkingPrivate.add(entry.key)) continue;
            unawaited(_checkPrivateSocket(entry.key, entry.value));
          }
        });
      } catch (_) {
        // Invalid private configuration/storage never disables public access.
        await privateRoute!.close();
      }
    }
    _audioTimer =
        Timer.periodic(const Duration(milliseconds: 10), (_) => _pumpAudio());
    _events = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_sockets.isEmpty) return;
      for (final entry in _sockets.entries.toList()) {
        if (!auth.valid(entry.value)) {
          if (!auth.sessions.any((s) => s.deviceId == entry.value.deviceId)) {
            coordinator.releaseDevice(entry.value.deviceId);
          }
          unawaited(entry.key.close(1008, 'session_revoked'));
          _sockets.remove(entry.key);
        } else if (!_pendingAck.containsKey(entry.key)) {
          _sendSnapshot(entry.key);
        } else if (DateTime.now().difference(_sentAt[entry.key]!) >
            const Duration(seconds: 5)) {
          unawaited(entry.key.close(1008, 'slow_client'));
          _forgetSocket(entry.key);
        }
      }
    });
  }

  bool _quickOrigin(Uri value) =>
      value.scheme == 'https' &&
      value.authority == value.host &&
      RegExp(r'^[a-z0-9-]+\.trycloudflare\.com$').hasMatch(value.host) &&
      value.path.isEmpty &&
      !value.hasQuery &&
      !value.hasFragment;

  void _rotateOrigin(Uri next) {
    if (origin == next) return;
    // A new tunnel is a new browser origin. Invalidate remote access only;
    // never stop/restart the engine or change its current playback/spatial state.
    ++_originEpoch;
    _transformStream?.close('origin_changed');
    if (_transformSocket != null) {
      unawaited(_transformSocket!.close(1001, 'origin_changed'));
      _forgetSocket(_transformSocket!);
    }
    _origin = next;
    _prelogin.clear();
    _captureProbeReports.clear();
    for (final session in auth.sessions.where((s) => !s.privateRoute)) {
      if (!auth.sessions
          .any((s) => s.privateRoute && s.deviceId == session.deviceId)) {
        coordinator.releaseDevice(session.deviceId);
      }
      auth.revoke(session);
    }
    for (final socket in _connections.toList()) {
      if (_privateSockets.containsKey(socket)) continue;
      unawaited(socket.close(1001, 'origin_changed'));
      _forgetSocket(socket);
    }
  }

  void _headers(HttpResponse response, {bool private = false}) {
    final secure = !private && _secure;
    final requestOrigin = private ? privateRoute?.origin ?? origin : origin;
    final websocketOrigin =
        requestOrigin.replace(scheme: secure ? 'wss' : 'ws');
    if (secure) {
      response.headers.set('Strict-Transport-Security', 'max-age=31536000');
    }
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Permissions-Policy',
          'microphone=(), camera=(), geolocation=(), display-capture=(self)')
      ..set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
              "connect-src 'self' $websocketOrigin; frame-src 'self'; worker-src 'self'; img-src 'self' data:; "
              "font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'");
  }

  Cookie _cookie(String name, String value, {int? maxAge}) =>
      Cookie(name, value)
        ..httpOnly = true
        ..secure = _secure
        ..sameSite = SameSite.strict
        ..path = '/'
        ..maxAge = maxAge;

  String? _requestCookie(HttpRequest request, String name) {
    final cookies = request.cookies.where((c) => c.name == name).toList();
    return cookies.length == 1 ? cookies.single.value : null;
  }

  Future<void> _json(HttpResponse response, Map<String, dynamic> value,
      [int status = 200]) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(value));
    await response.close();
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json' ||
        request.contentLength > 8192) {
      throw const RemoteFailure('invalid_body', httpStatus: 400);
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 5))) {
      bytes.addAll(chunk);
      if (bytes.length > 8192) {
        throw const RemoteFailure('body_too_large', httpStatus: 413);
      }
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const RemoteFailure('invalid_body', httpStatus: 400);
    }
    return value;
  }

  Future<void> _asset(HttpResponse response, String path, String type) async {
    final bytes = await loadAsset(path);
    response.headers.set('Content-Type', type);
    response.add(bytes);
    await response.close();
  }

  void _limit(String device) {
    final now = DateTime.now();
    _requests.removeWhere((_, times) =>
        times.isEmpty ||
        times.last.isBefore(now.subtract(const Duration(minutes: 1))));
    final entries = _requests.putIfAbsent(device, () => []);
    entries.removeWhere(
        (t) => t.isBefore(now.subtract(const Duration(seconds: 10))));
    if (entries.length >= 40) {
      throw const RemoteFailure('rate_limited', httpStatus: 429);
    }
    entries.add(now);
  }

  Map<String, dynamic> _snapshot(RemoteSession? session) => {
        ...coordinator.snapshot(device: session?.deviceId),
        if (privateRoute?.descriptor case final descriptor?)
          'privateRoute': descriptor,
      };

  Future<void> _checkPrivateSocket(
      WebSocket socket, ({String address, String pairId}) peer) async {
    try {
      await privateRoute!.verifyPeer(peer.address);
      if (privateRoute!.hasPair(peer.pairId)) return;
    } catch (_) {
      /* Fail closed, including a lost LocalAPI connection. */
    } finally {
      _checkingPrivate.remove(socket);
    }
    unawaited(socket.close(1008, 'private_identity_unavailable'));
    _forgetSocket(socket);
  }

  static const _privatePaths = {
    '/remote/api/private/pair',
    '/remote/api/private/resume',
    '/remote/api/session',
    '/remote/api/media',
    '/remote/api/control/lease',
    '/remote/api/commands',
    '/remote/api/ws-ticket',
    '/remote/api/auth/signout',
    '/remote/ws/events',
    '/remote/ws/audio',
  };

  bool _canMigrateAudio(RemoteSession session) =>
      privateRoute?.hasPair(session.pairId) == true &&
      session.deviceId == _audioSession?.deviceId;

  Future<void> _handle(HttpRequest request, {bool private = false}) async {
    final response = request.response;
    _headers(response, private: private);
    if (private ? _privateActive >= 4 : _active >= 16) {
      await _json(response, {'error': 'host_busy'}, 503);
      return;
    }
    if (private) {
      ++_privateActive;
    } else {
      ++_active;
    }
    final requestEpoch = _originEpoch;
    try {
      final requestOrigin = private ? privateRoute?.origin : origin;
      final cookieName = private ? 'yinwei_private' : _cookieName;
      if (private) {
        if (!_privatePaths.contains(request.uri.path)) {
          throw const RemoteFailure('not_found', httpStatus: 404);
        }
        final address = request.connectionInfo?.remoteAddress.address;
        if (address == null) {
          throw const RemoteFailure('private_peer_denied', httpStatus: 403);
        }
        await privateRoute!.verifyPeer(address);
      }
      // Do not trust forwarded headers or expose wildcard credentialed CORS.
      if (requestOrigin == null ||
          request.headers.value(HttpHeaders.hostHeader) !=
              requestOrigin.authority ||
          request.uri.hasQuery) {
        throw const RemoteFailure('invalid_host', httpStatus: 403);
      }
      if (!['GET', 'POST'].contains(request.method)) {
        throw const RemoteFailure('method_not_allowed', httpStatus: 405);
      }
      if ((request.method == 'POST' ||
              WebSocketTransformer.isUpgradeRequest(request)) &&
          request.headers.value('Origin') != requestOrigin.toString()) {
        throw const RemoteFailure('invalid_origin', httpStatus: 403);
      }
      final path = request.uri.path;
      if (request.method == 'POST' &&
          privateRoute != null &&
          (path == '/remote/api/private/pair' ||
              path == '/remote/api/private/resume')) {
        final data = await _body(request);
        final id = request.headers.value('X-Yinwei-Pair-Id');
        final key = request.headers.value('X-Yinwei-Pair-Key');
        if (path.endsWith('/pair')) {
          if (!private || data['ticket'] is! String || id == null) {
            throw const RemoteFailure('invalid_pairing_ticket',
                httpStatus: 401);
          }
          await privateRoute!.redeem(data['ticket'] as String, id);
        }
        final device = privateRoute!.verifyKey(id, key);
        // Replacing this client's route credentials must not consume a new
        // device slot or invalidate the other route's independent credentials.
        final previous = auth.authenticate(_requestCookie(request, cookieName));
        if (previous != null) auth.revoke(previous);
        final paired = auth.pairedSession(device, id!, privateRoute: private);
        response.cookies.add(Cookie(cookieName, paired.token)
          ..httpOnly = true
          ..secure = !private && _secure
          ..sameSite = SameSite.strict
          ..path = '/'
          ..maxAge = 28800);
        await _json(response, {
          'hostId': privateRoute!.hostId,
          'csrf': paired.session.csrf,
          'snapshot': _snapshot(paired.session)
        });
        return;
      }
      if (request.method == 'POST' && path == '/remote/internal/origin') {
        if (!allowOriginRotation ||
            request.connectionInfo?.remoteAddress.isLoopback != true ||
            request.headers.value('X-Yinwei-Host-Token') != hostToken) {
          throw const RemoteFailure('unauthorized', httpStatus: 401);
        }
        final body = await _body(request);
        final next = body['origin'] is String
            ? Uri.tryParse(body['origin'] as String)
            : null;
        if (body.length != 2 ||
            body['hostSessionId'] != coordinator.hostSessionId ||
            next == null ||
            !_quickOrigin(next) ||
            body['origin'] != next.toString() ||
            requestEpoch != _originEpoch) {
          throw const RemoteFailure('invalid_origin_rotation', httpStatus: 400);
        }
        _rotateOrigin(next);
        await _json(response, {'rotated': true});
        return;
      }
      if (request.method == 'GET' && path == '/remote/internal/readiness') {
        if (request.connectionInfo?.remoteAddress.isLoopback != true ||
            request.headers.value('X-Yinwei-Host-Token') != hostToken) {
          throw const RemoteFailure('unauthorized', httpStatus: 401);
        }
        await _json(response, {
          'service': 'yinwei-remote',
          'protocolVersion': 1,
          'hostSessionId': coordinator.hostSessionId,
          'nativeReady': coordinator.nativeBackend,
          'ownerEnabled': auth.account.enabled,
          'browserAudio': coordinator.browserAudioAvailable ||
              coordinator.browserLiveAudioAvailable,
          'browserLiveAudio': coordinator.browserLiveAudioAvailable,
        });
        return;
      }
      // Friend routes are handled entirely apart from the owner's: their own
      // cookies and sessions, never this owner session lookup.
      if (path == '/remote/guest' || path.startsWith('/remote/guest/')) {
        final guests = this.guests;
        if (guests == null) {
          throw const RemoteFailure('not_found', httpStatus: 404);
        }
        await guests.handle(request, response, (
          json: _json,
          body: _body,
          cookie: _cookie,
          requestCookie: _requestCookie,
          loadAsset: loadAsset,
          secure: _secure,
        ));
        return;
      }
      final session = auth.authenticate(_requestCookie(request, cookieName));
      if (private) {
        final id = request.headers.value('X-Yinwei-Pair-Id');
        final device = privateRoute!
            .verifyKey(id, request.headers.value('X-Yinwei-Pair-Key'));
        if (session == null ||
            !session.privateRoute ||
            session.pairId != id ||
            session.deviceId != device) {
          throw const RemoteFailure('pairing_required', httpStatus: 401);
        }
      } else if (session?.privateRoute == true) {
        throw const RemoteFailure('unauthorized', httpStatus: 401);
      }
      if (request.method == 'GET' && path == '/remote/health') {
        await _json(
            response, {'service': 'yinwei-remote', 'protocolVersion': 1});
        return;
      }
      if (request.method == 'GET' && (path == '/' || path == '/remote')) {
        response.redirect(origin.resolve('/remote/signin'), status: 303);
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/remote/signin') {
        _prelogin.removeWhere((_, expires) => expires.isBefore(DateTime.now()));
        if (_prelogin.length >= 128) {
          throw const RemoteFailure('login_limited', httpStatus: 429);
        }
        final nonce = remoteSecret();
        _prelogin[nonce] = DateTime.now().add(const Duration(minutes: 5));
        response.cookies.add(_cookie(_preloginCookieName, nonce, maxAge: 300));
        var html = utf8.decode(await loadAsset('assets/remote/signin.html'));
        html = html.replaceFirst('LOGIN_CSRF_TOKEN', nonce);
        response.headers.contentType = ContentType.html;
        response.write(html);
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/remote/signin.js') {
        await _asset(response, 'assets/remote/signin.js',
            'text/javascript; charset=utf-8');
        return;
      }
      if (request.method == 'GET' && path == '/remote/style.css') {
        await _asset(
            response, 'assets/remote/style.css', 'text/css; charset=utf-8');
        return;
      }
      if (request.method == 'POST' && path == '/remote/api/auth/signin') {
        final nonce = _requestCookie(request, _preloginCookieName);
        if (nonce == null ||
            _prelogin[nonce]?.isAfter(DateTime.now()) != true ||
            request.headers.value('X-CSRF-Token') != nonce) {
          throw const RemoteFailure('invalid_csrf', httpStatus: 403);
        }
        final data = await _body(request);
        if (data['username'] is! String || data['password'] is! String) {
          throw const RemoteFailure('invalid_body', httpStatus: 400);
        }
        final result = await auth.signin(
            data['username'] as String, data['password'] as String);
        if (requestEpoch != _originEpoch) {
          auth.revoke(result.session);
          throw const RemoteFailure('origin_changed', httpStatus: 409);
        }
        _prelogin.remove(nonce);
        response.cookies.add(_cookie(_cookieName, result.token, maxAge: 28800));
        response.cookies.add(_cookie(_preloginCookieName, '', maxAge: 0));
        await _json(response, {'signedIn': true});
        return;
      }
      if (session == null) {
        if ((path == '/remote/app' || path == '/remote/capture-probe') &&
            request.method == 'GET') {
          response.redirect(origin.resolve('/remote/signin'), status: 303);
          await response.close();
          return;
        }
        throw const RemoteFailure('unauthorized', httpStatus: 401);
      }
      if (request.method == 'POST') {
        _limit(session.deviceId);
        if (!auth.verifyCsrf(session, request.headers.value('X-CSRF-Token'))) {
          throw const RemoteFailure('invalid_csrf', httpStatus: 403);
        }
      }
      if (request.method == 'GET') {
        switch (path) {
          case '/remote/app':
            await _asset(
                response, 'assets/remote/app.html', 'text/html; charset=utf-8');
            return;
          case '/remote/app.js':
            await _asset(response, 'assets/remote/app.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/capture-probe':
            await _asset(response, 'assets/remote/capture-probe.html',
                'text/html; charset=utf-8');
            return;
          case '/remote/capture-probe.js':
            await _asset(response, 'assets/remote/capture-probe.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/capture-probe-core.js':
            await _asset(response, 'assets/remote/capture-probe-core.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/capture-meter-worklet.js':
            await _asset(response, 'assets/remote/capture-meter-worklet.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/workspace':
            var html = utf8
                .decode(await loadAsset('assets/spatial_workspace/index.html'));
            html = html
                .replaceFirst('</head>',
                    '<script src="/remote/workspace.js"></script></head>')
                .replaceFirst('vendor/three.min.js', '/remote/three.js')
                .replaceFirst('src="scene.js"', 'src="/remote/scene.js"');
            response.headers.contentType = ContentType.html;
            response.write(html);
            await response.close();
            return;
          case '/remote/workspace.js':
            await _asset(response, 'assets/remote/workspace.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/audio-client.js':
            await _asset(response, 'assets/remote/audio-client.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/audio-worklet.js':
            await _asset(response, 'assets/remote/audio-worklet.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/scene.js':
            await _asset(response, 'assets/spatial_workspace/scene.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/three.js':
            await _asset(
                response,
                'assets/spatial_workspace/vendor/three.min.js',
                'text/javascript; charset=utf-8');
            return;
          case '/remote/api/session':
            await _json(response, {
              'snapshot': _snapshot(session),
              'csrf': session.csrf,
              'owner': session.account.username,
              'entryLink': entryOrigin?.toString(),
              'remoteTransformAvailable': transformAdapter?.available == true
            });
            return;
          case '/remote/api/media':
            await _json(response, {'media': coordinator.media});
            return;
          case '/remote/api/capture-probe':
            await _json(response, {
              'reports': _captureProbeReports[session.deviceId] ?? const []
            });
            return;
          case '/remote/ws/events':
            if (!WebSocketTransformer.isUpgradeRequest(request) ||
                _connections.length + _upgrades >= 4) {
              throw const RemoteFailure('socket_unavailable', httpStatus: 429);
            }
            await _upgrade(request, session);
            return;
          case '/remote/ws/audio':
            final selected = _selectedAudioTap;
            if (selected == null ||
                (_audioSocket != null && !_canMigrateAudio(session)) ||
                !WebSocketTransformer.isUpgradeRequest(request) ||
                _connections.length + _upgrades >= 5) {
              throw const RemoteFailure('audio_unavailable');
            }
            await _upgrade(request, session,
                purpose: 'audio',
                selectedTap: selected,
                liveSource: coordinator.liveRunning());
            return;
          case '/remote/ws/transform':
            if (transformAdapter?.available != true ||
                _transformSocket != null ||
                _transformUpgradePending ||
                !WebSocketTransformer.isUpgradeRequest(request) ||
                _connections.length + _upgrades >= 5) {
              throw const RemoteFailure('transform_unavailable',
                  httpStatus: 409);
            }
            await _upgradeTransform(request, session);
            return;
        }
      } else {
        final data = await _body(request);
        switch (path) {
          case '/remote/api/auth/signout':
            if (privateRoute?.hasPair(session.pairId) == true) {
              await privateRoute!.revoke();
            }
            for (final related
                in auth.sessions.where((s) => s.deviceId == session.deviceId)) {
              _revoke(related);
            }
            _revoke(session);
            response.cookies.add(private
                ? (Cookie(cookieName, '')
                  ..httpOnly = true
                  ..path = '/'
                  ..maxAge = 0)
                : _cookie(cookieName, '', maxAge: 0));
            await _json(response, {'signedOut': true});
            return;
          case '/remote/api/control/lease':
            coordinator.snapshot();
            await _json(
              response,
              coordinator.acquireControl(session.deviceId,
                  auto: data['auto'] == true),
            );
            return;
          case '/remote/api/commands':
            try {
              await _json(
                  response, await coordinator.command(session.deviceId, data));
            } on RemoteFailure {
              rethrow;
            } catch (_) {
              throw const RemoteFailure('engine_failed', httpStatus: 503);
            }
            return;
          case '/remote/api/ws-ticket':
            if (private && !['events', 'audio'].contains(data['purpose'])) {
              throw const RemoteFailure('unsupported_stream', httpStatus: 400);
            }
            if (data['purpose'] == 'audio' &&
                _audioSocket != null &&
                !_canMigrateAudio(session)) {
              throw const RemoteFailure('audio_busy', httpStatus: 409);
            }
            if (!['events', 'audio', 'transform'].contains(data['purpose']) ||
                (data['purpose'] == 'audio' && _selectedAudioTap == null) ||
                (data['purpose'] == 'transform' &&
                    (transformAdapter?.available != true ||
                        _transformSocket != null))) {
              throw const RemoteFailure('unsupported_stream', httpStatus: 400);
            }
            await _json(response,
                {'ticket': auth.ticket(session, data['purpose'] as String)});
            return;
          case '/remote/api/private/pair-ticket':
            if (private || privateRoute == null) {
              throw const RemoteFailure('not_found', httpStatus: 404);
            }
            await _json(response, privateRoute!.issueTicket(session));
            return;
          case '/remote/api/private/revoke':
            if (privateRoute == null) {
              throw const RemoteFailure('not_found', httpStatus: 404);
            }
            await privateRoute!.revoke();
            await _json(response, {'revoked': true});
            return;
          case '/remote/api/owner/revoke-devices':
            if (privateRoute != null &&
                !privateRoute!.hasPair(session.pairId)) {
              await privateRoute!.revoke();
            }
            for (final other
                in auth.sessions.where((s) => !identical(s, session))) {
              _revoke(other);
            }
            await _json(response, {'revoked': true});
            return;
          case '/remote/api/capture-probe':
            final report = _sanitizeCaptureProbe(data);
            report['observedAt'] = DateTime.now().toUtc().toIso8601String();
            final reports = _captureProbeReports.putIfAbsent(
                session.deviceId, () => <Map<String, dynamic>>[]);
            reports.add(report);
            if (reports.length > 32) reports.removeAt(0);
            await _json(response, {'accepted': true});
            return;
        }
      }
      throw const RemoteFailure('not_found', httpStatus: 404);
    } on RemoteFailure catch (error) {
      await _json(response, {'error': error.code}, error.httpStatus);
    } on FormatException {
      await _json(response, {'error': 'invalid_body'}, 400);
    } catch (_) {
      // No stack traces, passwords, local media paths or account data over HTTP.
      try {
        await _json(response, {'error': 'request_failed'}, 503);
      } catch (_) {}
    } finally {
      if (private) {
        --_privateActive;
      } else {
        --_active;
      }
    }
  }

  void _revoke(RemoteSession session) {
    auth.revoke(session);
    coordinator.releaseDevice(session.deviceId);
    _requests.remove(session.deviceId);
    _captureProbeReports.remove(session.deviceId);
    if (identical(_transformSession, session)) {
      _transformStream?.close('session_revoked');
    }
    if (identical(_audioSession, session) && _audioSocket != null) {
      unawaited(_audioSocket!.close(1008, 'session_revoked'));
      _forgetSocket(_audioSocket!);
    }
    for (final entry in _sockets.entries.toList()) {
      if (identical(entry.value, session)) {
        _sockets.remove(entry.key);
        unawaited(entry.key.close(1008, 'session_revoked'));
      }
    }
  }

  Map<String, dynamic> _sanitizeCaptureProbe(Map<String, dynamic> data) {
    const allowed = {
      'version',
      'stage',
      'supported',
      'secureContext',
      'standalone',
      'visibility',
      'audioTrack',
      'videoTrack',
      'audioState',
      'sampleRate',
      'channelCount',
      'callbacks',
      'frames',
      'rmsDb',
      'peakDb',
      'silentCallbacks',
      'discontinuities',
      'maxGapMs',
      'tone997Db',
      'tone1499Db',
      'recaptureHint',
      'dryRouting',
      'errorCode'
    };
    if (data.keys.any((key) => !allowed.contains(key)) ||
        data['version'] != 1) {
      throw const RemoteFailure('invalid_probe_report', httpStatus: 400);
    }
    final report = <String, dynamic>{'version': 1};
    void enumValue(String key, Set<String> values) {
      final value = data[key];
      if (value != null && (value is! String || !values.contains(value))) {
        throw const RemoteFailure('invalid_probe_report', httpStatus: 400);
      }
      if (value != null) report[key] = value;
    }

    void boolean(String key) {
      final value = data[key];
      if (value != null && value is! bool) {
        throw const RemoteFailure('invalid_probe_report', httpStatus: 400);
      }
      if (value != null) report[key] = value;
    }

    void integer(String key, int min, int max) {
      final value = data[key];
      if (value != null && (value is! int || value < min || value > max)) {
        throw const RemoteFailure('invalid_probe_report', httpStatus: 400);
      }
      if (value != null) report[key] = value;
    }

    void finite(String key, double min, double max) {
      final value = data[key];
      if (value != null &&
          (value is! num || !value.isFinite || value < min || value > max)) {
        throw const RemoteFailure('invalid_probe_report', httpStatus: 400);
      }
      if (value != null) report[key] = value;
    }

    enumValue('stage', const {
      'capability',
      'requesting',
      'active',
      'tone',
      'stopped',
      'error'
    });
    enumValue('visibility', const {'visible', 'hidden', 'prerender'});
    enumValue('audioState', const {'missing', 'live', 'muted', 'ended'});
    enumValue('recaptureHint',
        const {'not_tested', 'clear', 'possible', 'inconclusive'});
    enumValue('dryRouting', const {
      'not_tested',
      'source_only',
      'source_plus_return',
      'return_only',
      'silent',
      'unsure'
    });
    enumValue('errorCode', const {
      'none',
      'unsupported',
      'not_allowed',
      'not_readable',
      'abort',
      'audio_context',
      'no_audio_track',
      'unknown'
    });
    for (final key in const [
      'supported',
      'secureContext',
      'standalone',
      'audioTrack',
      'videoTrack'
    ]) {
      boolean(key);
    }
    integer('sampleRate', 0, 384000);
    integer('channelCount', 0, 32);
    for (final key in const [
      'callbacks',
      'frames',
      'silentCallbacks',
      'discontinuities'
    ]) {
      integer(key, 0, 1000000000);
    }
    finite('rmsDb', -180, 24);
    finite('peakDb', -180, 24);
    finite('maxGapMs', 0, 600000);
    finite('tone997Db', -180, 24);
    finite('tone1499Db', -180, 24);
    return report;
  }

  Future<void> _upgrade(HttpRequest request, RemoteSession session,
      {String purpose = 'events',
      RemoteOutputSource? selectedTap,
      bool liveSource = false}) async {
    // Reserve capacity before awaiting the upgrade to avoid handshake races.
    ++_upgrades;
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request,
          compression: CompressionOptions.compressionOff);
    } finally {
      --_upgrades;
    }
    if (_connections.length >= 5 ||
        (purpose == 'audio' &&
            _audioSocket != null &&
            !_canMigrateAudio(session))) {
      await socket.close(1008, 'socket_limit');
      return;
    }
    _connections.add(socket);
    if (purpose == 'audio' && _audioSocket == null) _audioSocket = socket;
    if (session.privateRoute) {
      _privateSockets[socket] = (
        address: request.connectionInfo!.remoteAddress.address,
        pairId: session.pairId!
      );
    }
    socket.pingInterval = const Duration(seconds: 10);
    var authorized = false;
    final deadline = Timer(const Duration(seconds: 5), () {
      if (!authorized) unawaited(socket.close(1008, 'authentication_required'));
    });
    socket.listen((message) {
      if (message is! String || utf8.encode(message).length > 2048) {
        unawaited(socket.close(1008, 'invalid_message'));
        return;
      }
      try {
        final data = jsonDecode(message);
        if (authorized) {
          if (purpose == 'audio') {
            if (!identical(socket, _audioSocket)) {
              unawaited(socket.close(1000, 'route_migrated'));
              return;
            }
            if (data is Map && data.containsKey('quality')) {
              final quality = ListenQuality.parse(data['quality']);
              final stream = _audioStream;
              if (quality == null || stream == null) {
                unawaited(socket.close(1008, 'invalid_audio_quality'));
              } else {
                stream.quality = quality;
              }
              return;
            }
            if (data is Map && data['transport'] is String) {
              final udp = _udp;
              if (data['transport'] == 'udp' && udp != null && udp.active) {
                // Packets sent so far may still be acknowledged; UDP ones
                // never are, so the ack check must not wait for them.
                _audioViaUdp = true;
                _audioOutstanding.clear();
                if (_audioLastSent > _audioLastAck) _audioLastAck = _audioLastSent;
              } else {
                _audioToWebSocket(socket);
              }
              return;
            }
            final ack = data is Map ? data['ack'] : null;
            if (ack is int &&
                ack > 0 &&
                (ack <= _audioLastAck || _audioOutstanding.containsKey(ack))) {
              if (ack > _audioLastAck) {
                _audioOutstanding.removeWhere((sequence, _) => sequence <= ack);
                _audioLastAck = ack;
              }
            } else {
              unawaited(socket.close(1008, 'invalid_audio_ack'));
            }
            return;
          }
          if (data is Map && data['ack'] == _pendingAck[socket]) {
            _pendingAck.remove(socket);
            _sentAt.remove(socket);
          } else {
            unawaited(socket.close(1008, 'invalid_ack'));
          }
          return;
        }
        if (!auth.valid(session) ||
            data is! Map ||
            data['ticket'] is! String ||
            !auth.consumeTicket(session, data['ticket'] as String, purpose) ||
            (purpose == 'events' && _sockets.length >= 4)) {
          unawaited(socket.close(1008, 'invalid_ticket'));
          return;
        }
        authorized = true;
        deadline.cancel();
        if (purpose == 'audio') {
          final previous = _audioSocket;
          if (previous != null && !identical(previous, socket)) {
            if (!_canMigrateAudio(session)) {
              unawaited(socket.close(1008, 'audio_busy'));
              return;
            }
            // Transfer only after ticket authorization, synchronously between
            // pump ticks. A late onDone from the old socket cannot clear this one.
            _forgetSocket(previous);
            unawaited(previous.close(1000, 'route_migrated'));
          }
          _audioSocket = socket;
          _audioPacer.reset();
          _pacedPacket = null;
          if (!identical(selectedTap, _selectedAudioTap) ||
              selectedTap == null) {
            unawaited(socket.close(1008, 'audio_source_changed'));
            return;
          }
          _audioSession = session;
          _activeAudioTap = selectedTap;
          _activeAudioIsLive = liveSource;
          final quality = ListenQuality.parse(data['quality']);
          _audioStream?.close();
          _audioStream = quality == null
              ? null
              // The encoder exists even for lossless, so the iPad can switch.
              : ListenStreamSource(selectedTap,
                  encoder: createOpusEncoder?.call(), quality: quality);
          selectedTap.setEnabled(true);
          final stream = _audioStream;
          _audioViaUdp = false;
          // UDP only inside the private route, to the address it verified.
          final private = _privateSockets[socket];
          final transports = data['transports'];
          Map<String, Object>? udpOffer;
          if (listenUdp && private != null && stream != null) {
            final udp = _udp;
            if (udp == null) {
              _bindUdp(); // next audio session, once bound
            } else if (transports is List && transports.contains('udp')) {
              udpOffer = udp.offer(InternetAddress(private.address));
            }
          }
          socket.add(jsonEncode({
            'type': 'audioReady',
            'format': 'YNW1',
            'channels': 2,
            'source': liveSource ? 'live' : 'file',
            if (stream != null) ...{
              'codecs': ['pcm', if (stream.opusAvailable) 'opus'],
              'quality': stream.quality.name,
            },
            if (listenUdp) 'conceal': true,
            if (udpOffer != null) 'udp': udpOffer,
          }));
        } else {
          _sockets[socket] = session;
          _sendSnapshot(socket);
        }
      } catch (_) {
        unawaited(socket.close(1008, 'invalid_message'));
      }
    }, onDone: () {
      deadline.cancel();
      _forgetSocket(socket);
    }, onError: (Object _) {
      deadline.cancel();
      _forgetSocket(socket);
    });
  }

  void _sendSnapshot(WebSocket socket) {
    ListenTapTrace.mark('host.snapshot.sent');
    final sequence = ++_eventSequence;
    _pendingAck[socket] = sequence;
    _sentAt[socket] = DateTime.now();
    socket.add(jsonEncode({
      'type': 'snapshot',
      'sequence': sequence,
      'snapshot': _snapshot(_sockets[socket])
    }));
  }

  void _forgetSocket(WebSocket socket) {
    _privateSockets.remove(socket);
    if (identical(socket, _transformSocket)) {
      coordinator.setRemoteTransformRunning(false);
      _transformSocket = null;
      _transformSession = null;
      final stream = _transformStream;
      _transformStream = null;
      stream?.dispose();
    }
    if (identical(socket, _audioSocket)) {
      try {
        _activeAudioTap?.setEnabled(false);
      } catch (_) {}
      _audioSocket = null;
      _audioSession = null;
      _activeAudioTap = null;
      _audioStream?.close();
      _audioStream = null;
      _audioOutstanding.clear();
      _audioLastAck = 0;
      _audioLastSent = 0;
      _audioViaUdp = false;
      _udp?.end();
      _pacedPacket = null;
      _audioPacer.reset();
    }
    _sockets.remove(socket);
    _connections.remove(socket);
    _pendingAck.remove(socket);
    _sentAt.remove(socket);
  }

  Future<void> close() async {
    _privateChecks?.cancel();
    _udp?.close();
    _udp = null;
    await privateRoute?.close();
    _events?.cancel();
    _audioTimer?.cancel();
    _transformStream?.close('host_closed');
    for (final socket in _connections.toList()) {
      await socket
          .close(1001, 'host_closed')
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    _sockets.clear();
    _connections.clear();
    audioTap?.close();
    liveAudioTap?.close();
    guests?.close();
    transformAdapter?.close();
    auth.close();
    await _server?.close(force: true);
    _server = null;
    await coordinator.close();
  }

  Future<void> _upgradeTransform(
      HttpRequest request, RemoteSession session) async {
    // Reserve the lease synchronously, before the HTTP upgrade can yield.
    ++_upgrades;
    _transformUpgradePending = true;
    final epoch = ++_transformEpoch;
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request,
          compression: CompressionOptions.compressionOff);
    } finally {
      --_upgrades;
      _transformUpgradePending = false;
    }
    if (_transformSocket != null || !auth.valid(session)) {
      await socket.close(1008, 'transform_lease_unavailable');
      return;
    }
    _transformSocket = socket;
    _transformSession = session;
    _connections.add(socket);
    _transformStream = RemoteTransformSocket(
        socket: socket,
        adapter: transformAdapter!,
        epoch: epoch,
        sessionValid: () => auth.valid(session),
        consumeTicket: (ticket) =>
            auth.consumeTicket(session, ticket, 'transform'),
        onStarted: () => coordinator.setRemoteTransformRunning(true),
        onClosed: () => _forgetSocket(socket));
  }

  void _pumpAudio() {
    final socket = _audioSocket, session = _audioSession;
    if (socket == null || session == null) return;
    if (!identical(_activeAudioTap, _selectedAudioTap)) {
      unawaited(socket.close(
          1001,
          _activeAudioIsLive && !coordinator.liveRunning()
              ? 'live_stopped'
              : 'audio_source_changed'));
      _forgetSocket(socket);
      return;
    }
    final udp = _audioViaUdp ? _udp : null;
    if (udp != null && !udp.healthy()) {
      // The iPad's receiver reports stopped: back to WebSocket audio.
      _audioToWebSocket(socket, tell: true);
    }
    if (!auth.valid(session) ||
        (!_audioViaUdp &&
            _audioOutstanding.isNotEmpty &&
            DateTime.now().difference(_audioOutstanding.values.first) >
                const Duration(seconds: 5))) {
      unawaited(socket.close(1008, 'audio_session_ended'));
      _forgetSocket(socket);
      return;
    }
    try {
      if (_audioViaUdp) _udp?.tick();
      // Credit bounds transport memory (64 x 20 ms for Opus). Separate
      // media-time pacing prevents timer stalls turning into 80 ms bursts.
      // Over UDP there are no acks: the pacer alone keeps media pace.
      _audioPacer.tick(_audioPaceClock.elapsedMicroseconds);
      for (var i = 0;
          i < 4 && (_audioViaUdp || _audioOutstanding.length < audioCredit);
          ++i) {
        final packet =
            _pacedPacket ?? (_audioStream ?? _activeAudioTap!).read();
        if (packet == null) break;
        final metadata = ByteData.sublistView(packet);
        if (!_audioPacer.take(metadata.getUint32(36, Endian.little),
            metadata.getUint32(32, Endian.little))) {
          _pacedPacket = packet;
          break;
        }
        _pacedPacket = null;
        final sequence =
            ByteData.sublistView(packet).getUint64(16, Endian.little);
        if (sequence > _audioLastSent) _audioLastSent = sequence;
        // Lossless PCM (too big for two datagrams) still uses the WebSocket.
        if (_audioViaUdp && (_udp?.send(packet) ?? false)) continue;
        _audioOutstanding[sequence] = DateTime.now();
        socket.add(packet);
      }
    } catch (_) {
      unawaited(socket.close(1011, 'native_audio_failed'));
      _forgetSocket(socket);
    }
  }
}
