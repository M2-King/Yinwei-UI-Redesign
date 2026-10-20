import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

const remotePasswordIterations = 600000;

// Keep the isolate closure out of RemoteAuth's instance scope. An injected
// clock can capture a gateway/timer; only password derivation primitives may
// cross into the worker, never sessions or runtime state.
Future<String> _deriveOffThread(String password, String salt, int iterations) =>
    Isolate.run(() => _derivePassword(password, salt, iterations));

Future<String> _derivePassword(
    String password, String salt, int iterations) async {
  final key = await Pbkdf2.hmacSha256(iterations: iterations, bits: 256)
      .deriveKeyFromPassword(password: password, nonce: base64Url.decode(salt));
  return base64UrlEncode(await key.extractBytes());
}

bool _equalSecret(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var difference = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    difference |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return difference == 0;
}

class RemoteAccount {
  RemoteAccount(
      {required this.username,
      required this.salt,
      required this.hash,
      this.iterations = remotePasswordIterations,
      this.enabled = true});
  final String username;
  final String salt;
  final String hash;
  final int iterations;
  bool enabled;

  static Future<RemoteAccount> create(String username, String password) async {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,48}$').hasMatch(username) ||
        password.length < 12 ||
        utf8.encode(password).length > 1024) {
      throw const FormatException(
          'Username or password does not meet requirements');
    }
    final salt = base64UrlEncode(
        base64Url.decode(base64Url.normalize(remoteSecret(16))));
    final hash = await Isolate.run(
        () => _derivePassword(password, salt, remotePasswordIterations));
    return RemoteAccount(username: username, salt: salt, hash: hash);
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'role': 'owner',
        'algorithm': 'pbkdf2-hmac-sha256',
        'iterations': iterations,
        'salt': salt,
        'hash': hash,
        'enabled': enabled
      };

  static RemoteAccount fromJson(Map<String, dynamic> data) {
    final username = data['username'], salt = data['salt'], hash = data['hash'];
    final iterations = data['iterations'];
    if (username is! String ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,48}$').hasMatch(username) ||
        data['role'] != 'owner' ||
        data['algorithm'] != 'pbkdf2-hmac-sha256' ||
        salt is! String ||
        hash is! String ||
        iterations is! int ||
        iterations < remotePasswordIterations ||
        iterations > 1000000 ||
        base64Url.decode(salt).length != 16 ||
        base64Url.decode(hash).length != 32 ||
        data['enabled'] is! bool) {
      throw const FormatException('Invalid owner account configuration');
    }
    return RemoteAccount(
        username: username,
        salt: salt,
        hash: hash,
        iterations: iterations,
        enabled: data['enabled'] as bool);
  }
}

class RemoteSession {
  RemoteSession(this.account, this.deviceId, this.csrf, this.expires,
      {this.privateRoute = false, this.pairId});
  final RemoteAccount account;
  final String deviceId;
  final String csrf;
  final DateTime expires;
  final bool privateRoute;
  String? pairId;
}

class _Ticket {
  _Ticket(this.session, this.purpose, this.expires);
  final RemoteSession session;
  final String purpose;
  final DateTime expires;
}

/// First rollout is one explicitly provisioned owner. Sessions/tickets are
/// ephemeral and therefore fail closed across process restarts.
class RemoteAuth {
  RemoteAuth(this.account, {DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final RemoteAccount account;
  final DateTime Function() _now;
  final _sessions = <String, RemoteSession>{};
  final _tickets = <String, _Ticket>{};
  final _attempts = <DateTime>[];
  bool _hashing = false;
  bool _closed = false;

  static Future<RemoteAuth> load(File file) async {
    if (await file.length() > 16384) {
      throw const FormatException('Account file too large');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        (data['projectId'] != null && data['projectId'] != 'yinwei-remote') ||
        data['owner'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid account file');
    }
    return RemoteAuth(
        RemoteAccount.fromJson(data['owner'] as Map<String, dynamic>));
  }

  void _purge() {
    _sessions.removeWhere(
        (_, s) => !s.expires.isAfter(_now()) || !s.account.enabled);
    _tickets
        .removeWhere((_, t) => !t.expires.isAfter(_now()) || !valid(t.session));
  }

  bool valid(RemoteSession session) =>
      !_closed &&
      account.enabled &&
      session.expires.isAfter(_now()) &&
      _sessions.values.contains(session);

  List<RemoteSession> get sessions {
    _purge();
    return List.unmodifiable(_sessions.values);
  }

  Future<({String token, RemoteSession session})> signin(
      String username, String password) async {
    _purge();
    if (_closed) throw const RemoteFailure('host_closed', httpStatus: 503);
    _attempts.removeWhere(
        (t) => t.isBefore(_now().subtract(const Duration(minutes: 15))));
    if (_hashing || _attempts.length >= 10 || _sessions.length >= 8) {
      throw const RemoteFailure('login_limited', httpStatus: 429);
    }
    if (utf8.encode(password).length > 1024 || username.length > 48) {
      throw const RemoteFailure('invalid_credentials', httpStatus: 401);
    }
    _attempts.add(_now());
    _hashing = true;
    try {
      final salt = account.salt, iterations = account.iterations;
      final hash = await _deriveOffThread(password, salt, iterations);
      if (_closed) throw const RemoteFailure('host_closed', httpStatus: 503);
      if (!_equalSecret(hash, account.hash) ||
          username != account.username ||
          !account.enabled) {
        throw const RemoteFailure('invalid_credentials', httpStatus: 401);
      }
      final token = remoteSecret();
      final session = RemoteSession(account, remoteSecret(), remoteSecret(),
          _now().add(const Duration(hours: 8)));
      _sessions[_tokenHash(token)] = session;
      return (token: token, session: session);
    } finally {
      _hashing = false;
    }
  }

  static String _tokenHash(String token) =>
      crypto.sha256.convert(utf8.encode(token)).toString();

  /// Only a verified pairing may call this. It preserves the logical device
  /// across routes, so leases and command IDs keep their existing authority.
  ({String token, RemoteSession session}) pairedSession(
      String device, String pairId,
      {required bool privateRoute}) {
    _purge();
    if (_closed || !account.enabled) {
      throw const RemoteFailure('pairing_unavailable', httpStatus: 401);
    }
    final existing = _sessions.values
        .where((s) =>
            s.deviceId == device &&
            s.pairId == pairId &&
            s.privateRoute == privateRoute)
        .toList();
    for (final session in existing) {
      revoke(session);
    }
    if (_sessions.length >= 8) {
      throw const RemoteFailure('pairing_unavailable', httpStatus: 401);
    }
    final token = remoteSecret();
    final session = RemoteSession(
        account, device, remoteSecret(), _now().add(const Duration(hours: 8)),
        privateRoute: privateRoute, pairId: pairId);
    _sessions[_tokenHash(token)] = session;
    return (token: token, session: session);
  }

  RemoteSession? authenticate(String? token) {
    _purge();
    return token == null ? null : _sessions[_tokenHash(token)];
  }

  bool verifyCsrf(RemoteSession session, String? value) =>
      value != null && _equalSecret(session.csrf, value);

  String ticket(RemoteSession session, String purpose) {
    _purge();
    if (!valid(session)) {
      throw const RemoteFailure('unauthorized', httpStatus: 401);
    }
    if (!['events', 'audio', 'transform'].contains(purpose) ||
        _tickets.length >= 16) {
      throw const RemoteFailure('ticket_limited', httpStatus: 429);
    }
    final value = remoteSecret();
    _tickets[_tokenHash(value)] =
        _Ticket(session, purpose, _now().add(const Duration(seconds: 20)));
    return value;
  }

  bool consumeTicket(RemoteSession session, String value, String purpose) {
    _purge();
    final ticket = _tickets.remove(_tokenHash(value));
    return ticket != null &&
        identical(ticket.session, session) &&
        ticket.purpose == purpose;
  }

  void revoke(RemoteSession session) {
    _sessions.removeWhere((_, value) => identical(value, session));
    _purge();
  }

  void close() {
    _closed = true;
    _sessions.clear();
    _tickets.clear();
  }
}
