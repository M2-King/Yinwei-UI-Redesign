import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'remote_auth.dart';
import 'remote_protocol.dart';

/// Stage A is deliberately restricted to this laptop's WireGuard address.
const privateRouteAddress = '100.80.104.77';

class TailscalePeer {
  const TailscalePeer(this.login, this.nodeId, {this.tagged = false});
  final String login, nodeId;
  final bool tagged;
}

typedef PeerLookup = Future<TailscalePeer?> Function(String address);

/// Fixed executable, argument array, bounded execution/output, no shell. Nothing
/// from an HTTP header is passed to Tailscale: only the socket's peer address.
class TailscaleWhois {
  TailscaleWhois(this.executable);
  final String executable;

  Future<TailscalePeer?> call(String address) async {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || !File(executable).isAbsolute) return null;
    Process? process;
    var abandoned = false;
    final clock = Stopwatch()..start();
    try {
      final starting = Process.start(executable, ['whois', '--json', address],
              runInShell: false)
          .then((value) {
        if (abandoned) {
          value.kill();
          throw TimeoutException('whois_start_timeout');
        }
        return value;
      });
      process =
          await starting.timeout(const Duration(seconds: 2), onTimeout: () {
        abandoned = true;
        throw TimeoutException('whois_start_timeout');
      });
      final running = process;
      final remaining = const Duration(seconds: 2) - clock.elapsed;
      if (remaining <= Duration.zero) return null;
      Future<List<int>> bounded(Stream<List<int>> stream) async {
        final bytes = <int>[];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
          if (bytes.length > 65536) {
            running.kill();
            throw const FormatException('whois_output_limit');
          }
        }
        return bytes;
      }

      final result = await Future.wait<Object>([
        bounded(running.stdout),
        bounded(running.stderr),
        running.exitCode
      ]).timeout(remaining);
      if (result[2] != 0) return null;
      final value = jsonDecode(utf8.decode(result[0] as List<int>));
      if (value is! Map) return null;
      final node = value['Node'], user = value['UserProfile'];
      if (node is! Map ||
          user is! Map ||
          node['StableID'] is! String ||
          user['LoginName'] is! String) {
        return null;
      }
      return TailscalePeer(
          user['LoginName'] as String, node['StableID'] as String,
          tagged: node['Tags'] is List && (node['Tags'] as List).isNotEmpty);
    } catch (_) {
      return null;
    } finally {
      process?.kill();
    }
  }
}

class PrivateRouteConfig {
  PrivateRouteConfig(
      {required this.ownerLogin, required this.nodeId, this.port = 8443})
      : address = InternetAddress(privateRouteAddress) {
    if (!RegExp(r'^26098681@[^@\s]+$').hasMatch(ownerLogin) ||
        nodeId.isEmpty ||
        nodeId.length > 128 ||
        port < 1024 ||
        port > 65535) {
      throw const FormatException('Invalid private route configuration');
    }
  }

  /// Tests can open loopback only; no arbitrary interface injection.
  PrivateRouteConfig.loopbackForTesting(
      {required this.ownerLogin, required this.nodeId, this.port = 0})
      : address = InternetAddress.loopbackIPv4;

  final String ownerLogin, nodeId;
  final int port;
  final InternetAddress address;
}

class _PairTicket {
  _PairTicket(this.session, this.id, this.keyHash, this.expires);
  final RemoteSession session;
  final String id, keyHash;
  final DateTime expires;
}

/// Owns only private access, never an engine, tap reader, or capture session.
class PrivateRouteHost {
  PrivateRouteHost(
      {required this.config,
      required this.auth,
      required this.lookup,
      this.file,
      DateTime Function()? now,
      this.retryBase = const Duration(seconds: 1)})
      : _now = now ?? DateTime.now;

  final PrivateRouteConfig config;
  final RemoteAuth auth;
  final PeerLookup lookup;
  final File? file;
  final DateTime Function() _now;
  final Duration retryBase;
  final _tickets = <String, _PairTicket>{};
  final _peers = <String, ({TailscalePeer peer, DateTime expires})>{};
  final _lookups = <String, Future<TailscalePeer?>>{};
  Map<String, dynamic>? _pair;
  String hostId = remoteSecret();
  HttpServer? _server;
  Timer? _retry;
  bool _closed = false;
  int _attempt = 0;
  Future<void> _saving = Future.value();
  Future<void> _mutations = Future.value();
  bool _pairing = false;
  Future<void> Function(HttpRequest)? _handler;

  static PrivateRouteHost? fromEnvironment(
      Map<String, String> env, RemoteAuth auth) {
    if (env['YINWEI_TAILSCALE_ENABLED'] != '1') return null;
    final config = PrivateRouteConfig(
        ownerLogin: env['YINWEI_TAILSCALE_OWNER_LOGIN'] ?? '',
        nodeId: env['YINWEI_TAILSCALE_IPAD_NODE_ID'] ?? '',
        port: int.tryParse(env['YINWEI_TAILSCALE_PORT'] ?? '8443') ?? -1);
    final executable = env['YINWEI_TAILSCALE_EXE'] ??
        '${env['ProgramFiles'] ?? r'C:\Program Files'}\\Tailscale\\tailscale.exe';
    if (!File(executable).isAbsolute) {
      throw const FormatException('Tailscale executable must be absolute');
    }
    final localData = env['LOCALAPPDATA'];
    final pairPath = env['YINWEI_TAILSCALE_PAIR_FILE'] ??
        (localData == null
            ? null
            : '$localData/Yinwei/remote/private-route.json');
    if (pairPath == null ||
        !File(pairPath).isAbsolute ||
        RegExp(r'(^|[\\/])(outputs|assets|flutter_assets)([\\/]|$)|(^|[\\/])deployment\.json$',
                caseSensitive: false)
            .hasMatch(File(pairPath).absolute.path)) {
      throw const FormatException(
          'Pair record needs a private application-data path');
    }
    return PrivateRouteHost(
        config: config,
        auth: auth,
        lookup: TailscaleWhois(executable).call,
        file: File(pairPath));
  }

  String get _account => sha256
      .convert(utf8.encode(jsonEncode([
        auth.account.username,
        auth.account.salt,
        auth.account.hash,
        config.ownerLogin,
        config.nodeId
      ])))
      .toString();

  Uri? get origin => _server == null
      ? null
      : Uri(scheme: 'http', host: config.address.address, port: _server!.port);

  Map<String, dynamic>? get descriptor => origin == null
      ? null
      : {
          'version': 1,
          'hostId': hostId,
          'origin': origin.toString(),
          'transport': 'websocket',
        };

  Future<void> start(Future<void> Function(HttpRequest) handler) async {
    _handler = handler;
    if (file != null && await file!.exists()) {
      if (await file!.length() > 8192) {
        throw const FormatException('Pair record too large');
      }
      final value = jsonDecode(await file!.readAsString());
      if (value is! Map ||
          value['version'] != 1 ||
          value['kind'] != 'yinwei-private-route') {
        throw const FormatException('Invalid pair record');
      }
      if (value['account'] == _account && value['hostId'] is String) {
        hostId = value['hostId'] as String;
        if (value['pair'] is Map<String, dynamic>) {
          final pair = value['pair'] as Map<String, dynamic>;
          if (['id', 'hash', 'device'].every((k) => pair[k] is String)) {
            _pair = pair;
          }
        }
      }
    }
    await _save();
    await _bind();
  }

  Future<void> _save() => _saving = _saving.then((_) async {
        if (file == null) return;
        await file!.parent.create(recursive: true);
        final temporary = File('${file!.path}.$pid.tmp');
        await temporary.writeAsString(
            jsonEncode({
              'version': 1,
              'kind': 'yinwei-private-route',
              'account': _account,
              'hostId': hostId,
              'pair': _pair
            }),
            flush: true);
        await temporary.rename(file!.path);
      });

  Future<void> _bind() async {
    if (_closed || _server != null) return;
    try {
      final server =
          await HttpServer.bind(config.address, config.port, shared: false);
      if (_closed) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _attempt = 0;
      server.listen((request) => unawaited(_handler!(request)),
          onError: (Object _) {}, onDone: () {
        if (identical(_server, server)) _server = null;
        _scheduleBind();
      });
    } catch (_) {
      _scheduleBind();
    }
  }

  void _scheduleBind() {
    if (_closed || _retry?.isActive == true) return;
    final multiplier = 1 << (_attempt++).clamp(0, 5);
    _retry = Timer(retryBase * multiplier, () => unawaited(_bind()));
  }

  Future<void> verifyPeer(String address) async {
    final ip = InternetAddress.tryParse(address);
    final bytes = ip?.rawAddress;
    final tailscale = bytes != null &&
        bytes.length == 4 &&
        bytes[0] == 100 &&
        bytes[1] >= 64 &&
        bytes[1] <= 127;
    if (_closed ||
        !auth.account.enabled ||
        (!tailscale &&
            !(config.address.isLoopback && ip?.isLoopback == true))) {
      throw const RemoteFailure('private_peer_denied', httpStatus: 403);
    }
    final cached = _peers[address];
    TailscalePeer? peer;
    if (cached != null && cached.expires.isAfter(_now())) {
      peer = cached.peer;
    } else {
      // Bound concurrent verifier processes even under an unauthorized flood.
      if (_lookups.length >= 4 && !_lookups.containsKey(address)) {
        throw const RemoteFailure('private_identity_unavailable',
            httpStatus: 503);
      }
      final pending = _lookups.putIfAbsent(
          address, () => lookup(address).timeout(const Duration(seconds: 3)));
      try {
        peer = await pending;
      } catch (_) {
        peer = null;
      } finally {
        if (identical(_lookups[address], pending)) _lookups.remove(address);
      }
      if (peer != null) {
        if (_peers.length >= 16) _peers.clear();
        _peers[address] =
            (peer: peer, expires: _now().add(const Duration(seconds: 2)));
      }
    }
    if (peer == null) {
      throw const RemoteFailure('private_identity_unavailable',
          httpStatus: 503);
    }
    if (peer.tagged ||
        peer.login != config.ownerLogin ||
        peer.nodeId != config.nodeId) {
      throw const RemoteFailure('private_peer_denied', httpStatus: 403);
    }
  }

  Map<String, dynamic> issueTicket(RemoteSession session) {
    _tickets.removeWhere(
        (_, t) => !t.expires.isAfter(_now()) || !auth.valid(t.session));
    if (!auth.valid(session) || origin == null || _tickets.length >= 8) {
      throw const RemoteFailure('pairing_unavailable', httpStatus: 409);
    }
    final ticket = remoteSecret(), key = remoteSecret(), id = remoteSecret(16);
    _tickets[_hash(ticket)] = _PairTicket(
        session, id, _hash(key), _now().add(const Duration(seconds: 30)));
    return {
      'ticket': ticket,
      'pairId': id,
      'pairKey': key,
      'hostId': hostId,
      'origin': origin.toString()
    };
  }

  Future<void> _mutate(Future<void> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.catchError((Object _) {});
    return result;
  }

  Future<void> redeem(String ticket, String id) => _mutate(() async {
        final value = _tickets.remove(_hash(ticket));
        if (value == null ||
            value.id != id ||
            !value.expires.isAfter(_now()) ||
            !auth.valid(value.session)) {
          throw const RemoteFailure('invalid_pairing_ticket', httpStatus: 401);
        }
        final previous = _pair;
        _pairing = true;
        _pair = {
          'id': id,
          'hash': value.keyHash,
          'device': value.session.deviceId
        };
        try {
          await _save();
          if (_closed ||
              !auth.valid(value.session) ||
              !value.expires.isAfter(_now())) {
            _pair = previous;
            await _save();
            throw const RemoteFailure('invalid_pairing_ticket',
                httpStatus: 401);
          }
        } catch (_) {
          _pair = previous;
          rethrow;
        } finally {
          _pairing = false;
        }
        if (previous != null && previous['id'] != id) {
          for (final session
              in auth.sessions.where((s) => s.pairId == previous['id'])) {
            auth.revoke(session);
          }
        }
        value.session.pairId = id;
      });

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  bool hasPair(String? id) =>
      !_closed &&
      !_pairing &&
      auth.account.enabled &&
      id != null &&
      _pair?['id'] == id;

  String verifyKey(String? id, String? key) {
    final digest = _hash(key ?? '');
    final expected = _pair?['hash'] as String? ?? '';
    var different = digest.length ^ expected.length;
    for (var i = 0; i < digest.length; i++) {
      different |= digest.codeUnitAt(i) ^
          (i < expected.length ? expected.codeUnitAt(i) : 0);
    }
    if (!hasPair(id) || key == null || key.length > 128 || different != 0) {
      throw const RemoteFailure('pairing_required', httpStatus: 401);
    }
    return _pair!['device'] as String;
  }

  Future<void> revoke() {
    _tickets.clear();
    return _mutate(() async {
      final id = _pair?['id'];
      _pair = null;
      for (final session
          in auth.sessions.where((s) => s.pairId == id && id != null)) {
        auth.revoke(session);
      }
      await _save();
    });
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _tickets.clear();
    _peers.clear();
    await _server?.close(force: true);
    _server = null;
    await _mutations;
    await _saving.catchError((Object _) {});
  }
}
