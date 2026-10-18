import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'remote_transform.dart';

/// HTTP metadata only; never include credentials or response bodies in errors.
class RemoteRequestException extends HttpException {
  RemoteRequestException(this.path, this.statusCode)
      : super('Yinwei request failed ($statusCode)');
  final String path;
  final int statusCode;
}

/// Native transport only: capture and output devices are provided by the host.
/// No DSP, recording, automatic reconnect, or credentials in App Group storage.
class RemoteTransformClient {
  RemoteTransformClient(
      {required this.origin,
      required this.onOutput,
      this.onOutputReset,
      this.onState,
      bool allowLoopbackForTests = false}) {
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

  final Uri origin;
  final void Function(Uint8List) onOutput;
  final void Function()? onOutputReset;
  final void Function(String)? onState;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final _cookies = <String, String>{};
  final _pending = <int, DateTime>{};
  String? _csrf;
  WebSocket? _socket;
  Completer<void>? _ready;
  RemoteOutputValidator? _output;
  Timer? _watchdog;
  int _epoch = 0, _sequence = 0, _firstFrame = 0, _generation = 0;
  bool _starting = false, _disposed = false, _gap = true;
  int dropped = 0, accepted = 0, serverDropped = 0;
  int _inputCredit = RemoteTransformFlow.legacyInputCredit;
  double _tokens = RemoteTransformFlow.legacyInputCredit.toDouble();
  DateTime _tokenTime = DateTime.now();
  bool get connected => _socket != null && _epoch > 0;
  int get epoch => _epoch;
  int get pendingCount => _pending.length;

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? body, String? csrf}) async {
    final req = await _http
        .openUrl(body == null ? 'GET' : 'POST', origin.resolve(path))
        .timeout(const Duration(seconds: 5));
    req.followRedirects = false;
    req.headers.set('Origin', origin.toString().replaceAll(RegExp(r'/$'), ''));
    if (_cookies.isNotEmpty) req.headers.set('Cookie', _cookieHeader);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      if (csrf != null) req.headers.set('X-CSRF-Token', csrf);
      req.write(jsonEncode(body));
    }
    final deadline =
        Duration(seconds: path == '/remote/api/auth/signin' ? 60 : 10);
    final response = await req.close().timeout(deadline);
    final bytes = <int>[];
    await for (final chunk in response.timeout(deadline)) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) {
        throw const FormatException('response_too_large');
      }
    }
    if (response.statusCode != 200) {
      throw RemoteRequestException(path, response.statusCode);
    }
    for (final cookie in response.cookies) {
      if (![
            '__Host-yinwei',
            '__Host-yinwei_prelogin',
            'yinwei_local',
            'yinwei_prelogin'
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
    // The sign-in page is HTML; only its cookie is required by a native client.
    if (path == '/remote/signin') return const {};
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('invalid_response');
    }
    return value;
  }

  Future<void> signIn(String username, String password) async {
    if (_disposed || _starting || _socket != null) {
      throw StateError('Client busy');
    }
    _starting = true;
    final generation = _generation;
    try {
      _cookies.clear();
      _csrf = null;
      await _request('/remote/signin');
      final nonce =
          _cookies['__Host-yinwei_prelogin'] ?? _cookies['yinwei_prelogin'];
      if (nonce == null) throw const FormatException('prelogin_missing');
      await _request('/remote/api/auth/signin',
          csrf: nonce, body: {'username': username, 'password': password});
      final session = await _request('/remote/api/session');
      if (_disposed ||
          generation != _generation ||
          session['csrf'] is! String) {
        throw StateError('Sign-in cancelled');
      }
      _csrf = session['csrf'] as String;
      onState?.call('signedIn');
    } catch (_) {
      _cookies.clear();
      _csrf = null;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> start() async {
    if (_disposed || _starting || _socket != null || _csrf == null) {
      throw StateError('Sign in before starting a fresh transform session');
    }
    _starting = true;
    final generation = _generation;
    try {
      final grant = await _request('/remote/api/ws-ticket',
          csrf: _csrf, body: {'purpose': 'transform'});
      if (_disposed ||
          generation != _generation ||
          grant['ticket'] is! String) {
        throw StateError('Start cancelled');
      }
      var abandoned = false;
      final opening = WebSocket.connect(
              origin
                  .replace(
                      scheme: origin.scheme == 'https' ? 'wss' : 'ws',
                      path: '/remote/ws/transform')
                  .toString(),
              headers: {
                'Origin': origin.toString().replaceAll(RegExp(r'/$'), ''),
                'Cookie': _cookieHeader,
              },
              compression: CompressionOptions.compressionOff)
          .then((socket) {
        if (abandoned || _disposed || generation != _generation) {
          unawaited(socket.close());
          throw StateError('Start cancelled');
        }
        return socket;
      });
      final WebSocket socket;
      try {
        socket = await opening.timeout(const Duration(seconds: 5));
      } catch (_) {
        // A late handshake must not leave an orphan socket/lease alive.
        abandoned = true;
        rethrow;
      }
      if (_disposed || generation != _generation) {
        unawaited(socket.close());
        throw StateError('Start cancelled');
      }
      _socket = socket;
      _ready = Completer<void>();
      socket.pingInterval = const Duration(seconds: 10);
      socket.listen((message) {
        if (identical(socket, _socket)) _receive(message);
      }, onDone: () {
        if (identical(socket, _socket)) _lost('disconnected');
      }, onError: (Object _) {
        if (identical(socket, _socket)) _lost('disconnected');
      });
      socket.add(jsonEncode({'ticket': grant['ticket']}));
      await _ready!.future.timeout(const Duration(seconds: 5));
      if (!connected || _disposed || generation != _generation) {
        throw StateError('Start cancelled');
      }
      _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_pending.isNotEmpty &&
            DateTime.now().difference(_pending.values.first) >
                const Duration(seconds: 5)) {
          _lost('slowConnection');
        }
      });
    } catch (_) {
      _lost('startFailed');
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// Copy a single 10 ms chunk or drop it immediately. Never waits for WSS.
  /// Call from the transport worker, after bounded capture-edge resampling.
  bool trySend(Int16List pcm, {bool discontinuous = false}) {
    if (!connected || pcm.length != RemoteInputFrame.frames * 2) return false;
    _gap = _gap || discontinuous;
    final sequence = ++_sequence, firstFrame = _firstFrame;
    _firstFrame += RemoteInputFrame.frames;
    final now = DateTime.now();
    _tokens = (_tokens +
            now.difference(_tokenTime).inMicroseconds.clamp(0, 1000000) / 10000)
        .clamp(0, _inputCredit)
        .toDouble();
    _tokenTime = now;
    if (_tokens < 1 || _pending.length >= _inputCredit) {
      ++dropped;
      _gap = true;
      return false;
    }
    --_tokens;
    final packet = RemoteInputFrame.encode(
        epoch: _epoch,
        sequence: sequence,
        firstFrame: firstFrame,
        pcm: pcm,
        discontinuous: _gap);
    _pending[sequence] = now;
    _gap = false;
    try {
      _socket!.add(packet);
      return true;
    } catch (_) {
      _lost('disconnected');
      return false;
    }
  }

  void _receive(dynamic message) {
    try {
      if (message is List<int> && connected) {
        final packet = Uint8List.fromList(message);
        final sequence = _output!.validate(packet);
        onOutput(packet); // R2 hands off to a bounded native playback queue.
        _socket?.add(jsonEncode({'ack': sequence}));
        return;
      }
      if (message is! String || utf8.encode(message).length > 2048) {
        throw const FormatException('invalid_transform_message');
      }
      final data = jsonDecode(message);
      if (data is! Map) {
        throw const FormatException('invalid_transform_message');
      }
      if (!connected &&
          data['type'] == 'transformReady' &&
          data['epoch'] is int &&
          data['epoch'] > 0 &&
          data['epoch'] <= RemoteInputFrame.maxInteger &&
          data['inputFormat'] == 'YNI1' &&
          data['outputFormat'] == 'YNW1' &&
          data['sampleRate'] == 48000 &&
          data['channels'] == 2 &&
          data['frames'] == 480 &&
          ((data['inputCredit'] == RemoteTransformFlow.inputCredit &&
                  data['outputCredit'] == RemoteTransformFlow.outputCredit) ||
              (data['inputCredit'] == RemoteTransformFlow.legacyInputCredit &&
                  data['outputCredit'] ==
                      RemoteTransformFlow.legacyOutputCredit))) {
        _epoch = data['epoch'] as int;
        _sequence = _firstFrame = dropped = accepted = serverDropped = 0;
        // Never send more than the laptop's announced window.
        _inputCredit = data['inputCredit'] as int;
        _tokens = _inputCredit.toDouble();
        _tokenTime = DateTime.now();
        _gap = true;
        _output = RemoteOutputValidator(_epoch);
        _ready?.complete();
        onState?.call('connected');
      } else if (connected &&
          data['type'] == 'inputAck' &&
          data['epoch'] == _epoch &&
          data['sequence'] is int &&
          _pending.isNotEmpty &&
          data['sequence'] == _pending.keys.first &&
          data['accepted'] is bool &&
          data['dropped'] is int &&
          data['dropped'] >= serverDropped) {
        _pending.remove(data['sequence']);
        if (data['resetOutput'] == true) onOutputReset?.call();
        if (data['accepted'] == true) ++accepted;
        serverDropped = data['dropped'] as int;
      } else {
        throw const FormatException('invalid_transform_message');
      }
    } catch (_) {
      _lost('invalidStream');
    }
  }

  void _lost(String state) {
    final socket = _socket;
    _socket = null;
    _epoch = 0;
    _output = null;
    _pending.clear();
    _watchdog?.cancel();
    _watchdog = null;
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(StateError('Transform connection ended'));
    }
    if (socket != null) unawaited(socket.close(1000, state));
    onState?.call(state);
  }

  void stop() {
    ++_generation;
    _lost('stopped');
  }

  Future<void> signOut() async {
    stop();
    try {
      if (_csrf != null) {
        await _request('/remote/api/auth/signout', csrf: _csrf, body: {});
      }
    } finally {
      _csrf = null;
      _cookies.clear();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _csrf = null;
    _cookies.clear();
    _http.close(force: true);
  }
}
