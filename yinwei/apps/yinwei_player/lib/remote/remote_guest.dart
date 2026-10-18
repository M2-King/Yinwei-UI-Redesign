import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:yinwei_player/remote/remote_auth.dart'
    show remotePasswordIterations;
import 'package:yinwei_player/remote/remote_protocol.dart';

/// Option L, phase L0: friend ("guest") accounts, one-time invites and guest
/// sessions. Deliberately separate from the owner's [RemoteAuth]: its own
/// store file, cookies, sessions and `/remote/guest/*` routes. A guest
/// session can never authenticate an owner route, and the gateway only
/// mounts these routes when `YINWEI_GUEST_ENABLED=1`.

const guestInviteLifetime = Duration(hours: 24);
const guestSessionLifetime = Duration(hours: 8);
const guestMaxAccounts = 20;
const guestMaxOpenInvites = 10;
final _guestUsername = RegExp(r'^[a-zA-Z0-9_.-]{3,32}$');

// Top level so no instance state crosses into the isolate.
Future<String> _deriveGuest(String password, String salt, int iterations) =>
    Isolate.run(() async {
      final key = await Pbkdf2.hmacSha256(iterations: iterations, bits: 256)
          .deriveKeyFromPassword(
              password: password, nonce: base64Url.decode(salt));
      return base64UrlEncode(await key.extractBytes());
    });

String _sha256(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();

bool _sameSecret(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var difference = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    difference |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return difference == 0;
}

String _newSalt() =>
    base64UrlEncode(base64Url.decode(base64Url.normalize(remoteSecret(16))));

class GuestAccount {
  GuestAccount({
    required this.id,
    required this.username,
    required this.displayName,
    required this.salt,
    required this.hash,
    required this.iterations,
    required this.created,
    this.revoked,
  });

  final String id;
  final String username;
  final String displayName;
  final String salt;
  final String hash;
  final int iterations;
  final DateTime created;
  DateTime? revoked;

  bool get active => revoked == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'role': 'guest',
        'algorithm': 'pbkdf2-hmac-sha256',
        'iterations': iterations,
        'salt': salt,
        'hash': hash,
        'created': created.toUtc().toIso8601String(),
        'revoked': revoked?.toUtc().toIso8601String(),
      };

  static GuestAccount fromJson(Map<String, dynamic> data, int minIterations) {
    final iterations = data['iterations'];
    final salt = data['salt'], hash = data['hash'];
    if (data['id'] is! String ||
        data['username'] is! String ||
        !_guestUsername.hasMatch(data['username'] as String) ||
        data['displayName'] is! String ||
        data['role'] != 'guest' ||
        data['algorithm'] != 'pbkdf2-hmac-sha256' ||
        iterations is! int ||
        iterations < minIterations ||
        iterations > 1000000 ||
        salt is! String ||
        hash is! String ||
        base64Url.decode(salt).length != 16 ||
        base64Url.decode(hash).length != 32 ||
        data['created'] is! String ||
        (data['revoked'] != null && data['revoked'] is! String)) {
      throw const FormatException('Invalid guest account');
    }
    return GuestAccount(
      id: data['id'] as String,
      username: data['username'] as String,
      displayName: data['displayName'] as String,
      salt: salt,
      hash: hash,
      iterations: iterations,
      created: DateTime.parse(data['created'] as String),
      revoked: data['revoked'] == null
          ? null
          : DateTime.parse(data['revoked'] as String),
    );
  }
}

class _Invite {
  _Invite(this.hash, this.expires);
  final String hash;
  final DateTime expires;
}

class _GuestData {
  _GuestData(this.accounts, this.invites);
  final List<GuestAccount> accounts;
  final List<_Invite> invites;
}

/// Guest accounts and invites in `<dir>/guests.json`. Writes are atomic
/// (temp file + rename) under an exclusive lock, so the laptop-only admin
/// tool and the running gateway never lose each other's changes. Invite
/// tokens are stored only as SHA-256 hashes.
class GuestStore {
  GuestStore(
    this.directory, {
    this.iterations = remotePasswordIterations,
    this.minIterations = remotePasswordIterations,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Directory directory;

  /// PBKDF2 cost for new passwords. Tests lower both values; production
  /// keeps the owner's cost.
  final int iterations;
  final int minIterations;
  final DateTime Function() _now;
  _GuestData? _cache;
  DateTime? _cacheStamp;

  File get _file =>
      File('${directory.path}${Platform.pathSeparator}guests.json');
  File get _lock =>
      File('${directory.path}${Platform.pathSeparator}guests.lock');

  Future<_GuestData> _read() async {
    if (!await _file.exists()) return _GuestData([], []);
    final stat = await _file.stat();
    if (stat.size > 262144) {
      throw const FormatException('Guest store too large');
    }
    if (_cache != null && _cacheStamp == stat.modified) return _cache!;
    final value = jsonDecode(await _file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['projectId'] != 'yinwei-remote' ||
        value['accounts'] is! List ||
        value['invites'] is! List) {
      throw const FormatException('Invalid guest store');
    }
    final data = _GuestData(
      [
        for (final a in value['accounts'] as List)
          GuestAccount.fromJson(a as Map<String, dynamic>, minIterations)
      ],
      [
        for (final i in value['invites'] as List)
          _Invite((i as Map)['hash'] as String,
              DateTime.parse(i['expires'] as String))
      ],
    );
    _cache = data;
    _cacheStamp = stat.modified;
    return data;
  }

  Future<T> _update<T>(T Function(_GuestData data) change) async {
    await directory.create(recursive: true);
    final lock = await _lock.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      _cache = null;
      final data = await _read();
      final result = change(data);
      final now = _now();
      data.invites.removeWhere((i) => !i.expires.isAfter(now));
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'projectId': 'yinwei-remote',
          'accounts': [for (final a in data.accounts) a.toJson()],
          'invites': [
            for (final i in data.invites)
              {'hash': i.hash, 'expires': i.expires.toUtc().toIso8601String()}
          ],
        }),
        flush: true,
      );
      await temp.rename(_file.path);
      _cache = null;
      return result;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  /// Laptop-only: creates a one-time invite and returns its raw token.
  Future<String> createInvite() async {
    final token = remoteSecret(24);
    await _update((data) {
      final now = _now();
      data.invites.removeWhere((i) => !i.expires.isAfter(now));
      if (data.invites.length >= guestMaxOpenInvites) {
        throw const RemoteFailure('too_many_invites', httpStatus: 429);
      }
      if (data.accounts.where((a) => a.active).length >= guestMaxAccounts) {
        throw const RemoteFailure('guest_limit', httpStatus: 409);
      }
      data.invites.add(_Invite(_sha256(token), now.add(guestInviteLifetime)));
    });
    return token;
  }

  Future<bool> inviteValid(String token) async {
    final hash = _sha256(token), now = _now();
    return (await _read())
        .invites
        .any((i) => _sameSecret(i.hash, hash) && i.expires.isAfter(now));
  }

  /// Consumes [token] and creates the account. The invite is checked again
  /// under the lock, so it can be used once even with concurrent requests.
  Future<GuestAccount> acceptInvite({
    required String token,
    required String username,
    required String displayName,
    required String password,
  }) async {
    final name = displayName.trim();
    if (!_guestUsername.hasMatch(username) ||
        name.isEmpty ||
        name.length > 40 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        password.length < 12 ||
        utf8.encode(password).length > 1024) {
      throw const RemoteFailure('invalid_account_details', httpStatus: 400);
    }
    if (!await inviteValid(token)) {
      throw const RemoteFailure('invalid_invite', httpStatus: 403);
    }
    final salt = _newSalt();
    final hash = await _deriveGuest(password, salt, iterations);
    final account = GuestAccount(
      id: remoteSecret(12),
      username: username,
      displayName: name,
      salt: salt,
      hash: hash,
      iterations: iterations,
      created: _now(),
    );
    return _update((data) {
      final tokenHash = _sha256(token), now = _now();
      final invite = data.invites
          .where(
              (i) => _sameSecret(i.hash, tokenHash) && i.expires.isAfter(now))
          .firstOrNull;
      if (invite == null) {
        throw const RemoteFailure('invalid_invite', httpStatus: 403);
      }
      if (data.accounts
          .any((a) => a.username.toLowerCase() == username.toLowerCase())) {
        throw const RemoteFailure('username_taken', httpStatus: 409);
      }
      if (data.accounts.where((a) => a.active).length >= guestMaxAccounts) {
        throw const RemoteFailure('guest_limit', httpStatus: 409);
      }
      data.invites.remove(invite);
      data.accounts.add(account);
      return account;
    });
  }

  Future<List<GuestAccount>> accounts() async =>
      List.unmodifiable((await _read()).accounts);

  Future<GuestAccount?> find(String username) async => (await _read())
      .accounts
      .where((a) => a.username.toLowerCase() == username.toLowerCase())
      .firstOrNull;

  Future<GuestAccount?> byId(String id) async =>
      (await _read()).accounts.where((a) => a.id == id).firstOrNull;

  /// Laptop-only. Revoked guests keep their record (and later their
  /// library folder) until the owner deletes them.
  Future<bool> revoke(String username) => _update((data) {
        final account = data.accounts
            .where((a) => a.username.toLowerCase() == username.toLowerCase())
            .firstOrNull;
        if (account == null || !account.active) return false;
        account.revoked = _now();
        return true;
      });
}

class GuestSession {
  GuestSession(this.accountId, this.deviceId, this.csrf, this.expires);
  final String accountId;
  final String deviceId;
  final String csrf;
  final DateTime expires;
}

/// Guest sessions: same password cost, constant-time compare, one hash at a
/// time and sign-in rate limit as the owner, but a separate session table.
class GuestAuth {
  GuestAuth(this.store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final GuestStore store;
  final DateTime Function() _now;
  final _sessions = <String, GuestSession>{};
  final _attempts = <DateTime>[];
  bool _hashing = false;

  // Used when the username does not exist, so timing does not reveal it.
  late final String _decoySalt = _newSalt();

  Future<({String token, GuestSession session})> signin(
      String username, String password) async {
    _purge();
    _attempts.removeWhere(
        (t) => t.isBefore(_now().subtract(const Duration(minutes: 15))));
    if (_hashing || _attempts.length >= 10 || _sessions.length >= 32) {
      throw const RemoteFailure('login_limited', httpStatus: 429);
    }
    if (utf8.encode(password).length > 1024 || username.length > 32) {
      throw const RemoteFailure('invalid_credentials', httpStatus: 401);
    }
    _attempts.add(_now());
    _hashing = true;
    try {
      final account = await store.find(username);
      final hash = await _deriveGuest(password, account?.salt ?? _decoySalt,
          account?.iterations ?? store.iterations);
      if (account == null ||
          !account.active ||
          !_sameSecret(hash, account.hash)) {
        throw const RemoteFailure('invalid_credentials', httpStatus: 401);
      }
      final token = remoteSecret();
      final session = GuestSession(account.id, remoteSecret(), remoteSecret(),
          _now().add(guestSessionLifetime));
      _sessions[_sha256(token)] = session;
      return (token: token, session: session);
    } finally {
      _hashing = false;
    }
  }

  void _purge() => _sessions.removeWhere((_, s) => !s.expires.isAfter(_now()));

  /// Session plus its account, or null if expired, unknown or revoked.
  Future<({GuestSession session, GuestAccount account})?> authenticate(
      String? token) async {
    _purge();
    if (token == null) return null;
    final session = _sessions[_sha256(token)];
    if (session == null) return null;
    final account = await store.byId(session.accountId);
    if (account == null || !account.active) {
      _sessions.removeWhere((_, s) => identical(s, session));
      return null;
    }
    return (session: session, account: account);
  }

  bool verifyCsrf(GuestSession session, String? value) =>
      value != null && _sameSecret(session.csrf, value);

  void revoke(GuestSession session) =>
      _sessions.removeWhere((_, s) => identical(s, session));

  void close() => _sessions.clear();
}

/// Request helpers borrowed from the gateway so guest routes share its
/// JSON limits, cookie flags and asset loading.
typedef GuestHttp = ({
  Future<void> Function(HttpResponse response, Map<String, dynamic> value,
      [int status]) json,
  Future<Map<String, dynamic>> Function(HttpRequest request) body,
  Cookie Function(String name, String value, {int? maxAge}) cookie,
  String? Function(HttpRequest request, String name) requestCookie,
  Future<List<int>> Function(String asset) loadAsset,
  bool secure,
});

/// `/remote/guest/*` routes. Host, Origin and method checks already ran in
/// the gateway; errors are thrown as [RemoteFailure] and rendered there.
class GuestService {
  GuestService(this.store, {GuestAuth? auth}) : auth = auth ?? GuestAuth(store);

  final GuestStore store;
  final GuestAuth auth;
  final _prelogin = <String, DateTime>{};

  static String sessionCookie(bool secure) =>
      secure ? '__Host-yinwei_guest' : 'yinwei_guest_local';
  static String preloginCookie(bool secure) =>
      secure ? '__Host-yinwei_guest_pre' : 'yinwei_guest_pre';

  Future<void> handle(
      HttpRequest request, HttpResponse response, GuestHttp http) async {
    final path = request.uri.path;
    final get = request.method == 'GET', post = request.method == 'POST';

    if (get && (path == '/remote/guest' || path == '/remote/guest/')) {
      response.redirect(Uri(path: '/remote/guest/signin'), status: 303);
      await response.close();
      return;
    }
    if (get &&
        (path == '/remote/guest/signin' || path == '/remote/guest/invite')) {
      await _page(response, http, path.endsWith('invite') ? 'invite' : 'signin',
          prelogin: true);
      return;
    }
    if (get && path == '/remote/guest/guest.js') {
      response.headers.set('Content-Type', 'text/javascript; charset=utf-8');
      response.add(await http.loadAsset('assets/remote/guest.js'));
      await response.close();
      return;
    }
    if (post &&
        (path == '/remote/guest/api/invite' ||
            path == '/remote/guest/api/signin')) {
      final nonce = http.requestCookie(request, preloginCookie(http.secure));
      if (nonce == null ||
          _prelogin[nonce]?.isAfter(DateTime.now()) != true ||
          request.headers.value('X-CSRF-Token') != nonce) {
        throw const RemoteFailure('invalid_csrf', httpStatus: 403);
      }
      final data = await http.body(request);
      if (path.endsWith('invite')) {
        for (final key in ['token', 'username', 'displayName', 'password']) {
          if (data[key] is! String) {
            throw const RemoteFailure('invalid_body', httpStatus: 400);
          }
        }
        await store.acceptInvite(
          token: data['token'] as String,
          username: data['username'] as String,
          displayName: data['displayName'] as String,
          password: data['password'] as String,
        );
      }
      if (data['username'] is! String || data['password'] is! String) {
        throw const RemoteFailure('invalid_body', httpStatus: 400);
      }
      final result = await auth.signin(
          data['username'] as String, data['password'] as String);
      _prelogin.remove(nonce);
      response.cookies
        ..add(http.cookie(sessionCookie(http.secure), result.token,
            maxAge: guestSessionLifetime.inSeconds))
        ..add(http.cookie(preloginCookie(http.secure), '', maxAge: 0));
      await http.json(response, {'signedIn': true});
      return;
    }

    final signedIn = await auth
        .authenticate(http.requestCookie(request, sessionCookie(http.secure)));
    if (signedIn == null) {
      if (get && path == '/remote/guest/room') {
        response.redirect(Uri(path: '/remote/guest/signin'), status: 303);
        await response.close();
        return;
      }
      throw const RemoteFailure('unauthorized', httpStatus: 401);
    }
    if (post &&
        !auth.verifyCsrf(
            signedIn.session, request.headers.value('X-CSRF-Token'))) {
      throw const RemoteFailure('invalid_csrf', httpStatus: 403);
    }
    if (get && path == '/remote/guest/room') {
      await _page(response, http, 'room');
      return;
    }
    if (get && path == '/remote/guest/api/session') {
      await http.json(response, {
        'role': 'guest',
        'displayName': signedIn.account.displayName,
        'username': signedIn.account.username,
        'csrf': signedIn.session.csrf,
      });
      return;
    }
    if (post && path == '/remote/guest/api/signout') {
      auth.revoke(signedIn.session);
      response.cookies
          .add(http.cookie(sessionCookie(http.secure), '', maxAge: 0));
      await http.json(response, {'signedOut': true});
      return;
    }
    throw const RemoteFailure('not_found', httpStatus: 404);
  }

  Future<void> _page(HttpResponse response, GuestHttp http, String mode,
      {bool prelogin = false}) async {
    var nonce = '';
    if (prelogin) {
      final now = DateTime.now();
      _prelogin.removeWhere((_, expires) => expires.isBefore(now));
      if (_prelogin.length >= 128) {
        throw const RemoteFailure('login_limited', httpStatus: 429);
      }
      nonce = remoteSecret();
      _prelogin[nonce] = now.add(const Duration(minutes: 10));
      response.cookies
          .add(http.cookie(preloginCookie(http.secure), nonce, maxAge: 600));
    }
    final html = utf8
        .decode(await http.loadAsset('assets/remote/guest.html'))
        .replaceFirst('GUEST_MODE', mode)
        .replaceFirst('GUEST_CSRF_TOKEN', nonce);
    response.headers.contentType = ContentType.html;
    response.write(html);
    await response.close();
  }

  void close() {
    auth.close();
    _prelogin.clear();
  }
}
