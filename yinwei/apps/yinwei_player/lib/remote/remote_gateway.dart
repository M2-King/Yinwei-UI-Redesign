import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/native_output_tap.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';

typedef RemoteAssetLoader = Future<Uint8List> Function(String asset);

class RemoteGateway {
  RemoteGateway(
      {required this.auth,
      required this.coordinator,
      required this.loadAsset,
      this.entryOrigin,
      this.allowOriginRotation = false,
      this.audioTap,
      this.liveAudioTap});
  final bool allowOriginRotation;
  final RemoteOutputSource? audioTap;
  final RemoteOutputSource? liveAudioTap;
  final Uri? entryOrigin;
  final RemoteAuth auth;
  final String hostToken = remoteSecret(32);
  final AppSessionCoordinator coordinator;
  final RemoteAssetLoader loadAsset;
  HttpServer? _server;
  Uri? _origin;
  bool _secure = false;
  int _originEpoch = 0;
  int _active = 0;
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
  bool _activeAudioIsLive = false;
  final _audioOutstanding = <int, DateTime>{};
  int _audioLastAck = 0;
  RemoteOutputSource? get _selectedAudioTap => coordinator.liveRunning()
      ? (coordinator.liveReady ? liveAudioTap : null)
      : (coordinator.controller.array.enabled ? null : audioTap);
  Timer? _audioTimer;
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
    _audioTimer =
        Timer.periodic(const Duration(milliseconds: 10), (_) => _pumpAudio());
    _events = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_sockets.isEmpty) return;
      for (final entry in _sockets.entries.toList()) {
        if (!auth.valid(entry.value)) {
          coordinator.releaseDevice(entry.value.deviceId);
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
    _origin = next;
    _prelogin.clear();
    _captureProbeReports.clear();
    for (final session in auth.sessions) {
      coordinator.releaseDevice(session.deviceId);
      auth.revoke(session);
    }
    for (final socket in _connections.toList()) {
      unawaited(socket.close(1001, 'origin_changed'));
      _forgetSocket(socket);
    }
  }

  void _headers(HttpResponse response) {
    final websocketOrigin = origin.replace(scheme: _secure ? 'wss' : 'ws');
    if (_secure) {
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

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _headers(response);
    if (_active >= 16) {
      await _json(response, {'error': 'host_busy'}, 503);
      return;
    }
    ++_active;
    final requestEpoch = _originEpoch;
    try {
      // Do not trust forwarded headers or expose wildcard credentialed CORS.
      if (request.headers.value(HttpHeaders.hostHeader) != origin.authority ||
          request.uri.hasQuery) {
        throw const RemoteFailure('invalid_host', httpStatus: 403);
      }
      if (!['GET', 'POST'].contains(request.method)) {
        throw const RemoteFailure('method_not_allowed', httpStatus: 405);
      }
      if ((request.method == 'POST' ||
              WebSocketTransformer.isUpgradeRequest(request)) &&
          request.headers.value('Origin') != origin.toString()) {
        throw const RemoteFailure('invalid_origin', httpStatus: 403);
      }
      final path = request.uri.path;
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
      final session = auth.authenticate(_requestCookie(request, _cookieName));
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
              'snapshot': coordinator.snapshot(device: session.deviceId),
              'csrf': session.csrf,
              'owner': session.account.username,
              'entryLink': entryOrigin?.toString()
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
                _audioSocket != null ||
                !WebSocketTransformer.isUpgradeRequest(request) ||
                _connections.length + _upgrades >= 5) {
              throw const RemoteFailure('audio_unavailable');
            }
            await _upgrade(request, session,
                purpose: 'audio',
                selectedTap: selected,
                liveSource: coordinator.liveRunning());
            return;
        }
      } else {
        final data = await _body(request);
        switch (path) {
          case '/remote/api/auth/signout':
            _revoke(session);
            response.cookies.add(_cookie(_cookieName, '', maxAge: 0));
            await _json(response, {'signedOut': true});
            return;
          case '/remote/api/control/lease':
            coordinator.snapshot();
            await _json(response, coordinator.acquireControl(session.deviceId));
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
            if (!['events', 'audio'].contains(data['purpose']) ||
                (data['purpose'] == 'audio' && _selectedAudioTap == null)) {
              throw const RemoteFailure('unsupported_stream', httpStatus: 400);
            }
            await _json(response,
                {'ticket': auth.ticket(session, data['purpose'] as String)});
            return;
          case '/remote/api/owner/revoke-devices':
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
      --_active;
    }
  }

  void _revoke(RemoteSession session) {
    auth.revoke(session);
    coordinator.releaseDevice(session.deviceId);
    _requests.remove(session.deviceId);
    _captureProbeReports.remove(session.deviceId);
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
        (purpose == 'audio' && _audioSocket != null)) {
      await socket.close(1008, 'socket_limit');
      return;
    }
    _connections.add(socket);
    if (purpose == 'audio') _audioSocket = socket;
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
          if (!identical(selectedTap, _selectedAudioTap) ||
              selectedTap == null) {
            unawaited(socket.close(1008, 'audio_source_changed'));
            return;
          }
          _audioSession = session;
          _activeAudioTap = selectedTap;
          _activeAudioIsLive = liveSource;
          selectedTap.setEnabled(true);
          socket.add(jsonEncode({
            'type': 'audioReady',
            'format': 'YNW1',
            'channels': 2,
            'source': liveSource ? 'live' : 'file'
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
    final sequence = ++_eventSequence;
    _pendingAck[socket] = sequence;
    _sentAt[socket] = DateTime.now();
    socket.add(jsonEncode({
      'type': 'snapshot',
      'sequence': sequence,
      'snapshot': coordinator.snapshot(device: _sockets[socket]?.deviceId)
    }));
  }

  void _forgetSocket(WebSocket socket) {
    if (identical(socket, _audioSocket)) {
      try {
        _activeAudioTap?.setEnabled(false);
      } catch (_) {}
      _audioSocket = null;
      _audioSession = null;
      _activeAudioTap = null;
      _audioOutstanding.clear();
      _audioLastAck = 0;
    }
    _sockets.remove(socket);
    _connections.remove(socket);
    _pendingAck.remove(socket);
    _sentAt.remove(socket);
  }

  Future<void> close() async {
    _events?.cancel();
    _audioTimer?.cancel();
    for (final socket in _connections.toList()) {
      await socket
          .close(1001, 'host_closed')
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    _sockets.clear();
    _connections.clear();
    audioTap?.close();
    liveAudioTap?.close();
    auth.close();
    await _server?.close(force: true);
    _server = null;
    await coordinator.close();
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
    if (!auth.valid(session) ||
        (_audioOutstanding.isNotEmpty &&
            DateTime.now().difference(_audioOutstanding.values.first) >
                const Duration(seconds: 5))) {
      unawaited(socket.close(1008, 'audio_session_ended'));
      _forgetSocket(socket);
      return;
    }
    try {
      // At most 24 unacknowledged chunks: bounded network credit, not an
      // unlimited WebSocket send queue. Native production never waits here.
      for (var i = 0; i < 2 && _audioOutstanding.length < 24; ++i) {
        final packet = _activeAudioTap!.read();
        if (packet == null) break;
        final sequence =
            ByteData.sublistView(packet).getUint64(16, Endian.little);
        _audioOutstanding[sequence] = DateTime.now();
        socket.add(packet);
      }
    } catch (_) {
      unawaited(socket.close(1011, 'native_audio_failed'));
      _forgetSocket(socket);
    }
  }
}
