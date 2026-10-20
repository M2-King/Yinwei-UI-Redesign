import 'dart:async';
import 'dart:io';

import 'private_pair_store.dart';
import 'remote_owner_client.dart';

/// Native Listen only. Browsers, Live capture clients, and old hosts retain
/// RemoteOwnerClient unchanged. A route is not a second logical controller.
class RoutedOwnerClient extends RemoteOwnerClient {
  RoutedOwnerClient(
      {required RemoteOwnerClient publicClient,
      required this.entry,
      required this.store,
      required this.reconnectPublic,
      required this.onMigration,
      this.networkChanges,
      this.onNetworkChange,
      RemoteOwnerClient Function(PrivatePair)? privateClientFor,
      this.allowEnrollment = true,
      this.loopbackForTesting = false,
      this.probeInterval = const Duration(seconds: 3),
      this.switchbackDelay = const Duration(seconds: 10)})
      : _public = publicClient,
        _active = publicClient,
        _privateClientFor = privateClientFor ?? RemoteOwnerClient.privateRoute,
        super(
            origin: publicClient.origin,
            allowLoopbackForTests: loopbackForTesting);

  final String entry;
  final PrivatePairStore store;
  final Future<RemoteOwnerClient> Function() reconnectPublic;
  final void Function() onMigration;
  final Stream<void>? networkChanges;
  final void Function()? onNetworkChange;
  StreamSubscription<void>? _networkSubscription;
  final RemoteOwnerClient Function(PrivatePair) _privateClientFor;
  final bool allowEnrollment, loopbackForTesting;
  final Duration probeInterval, switchbackDelay;
  RemoteOwnerClient _public, _active;
  RemoteOwnerClient? _private;
  PrivatePair? _pair;
  Timer? _timer;
  bool _ended = false, _probing = false, _enrolling = false;
  Future<bool>? _recovering;
  DateTime? _healthySince, _lastFailure;
  int _successes = 0;
  int _probeFailures = 0;
  DateTime? _nextProbe, _enrollmentAttempt;
  int generation = 0, switches = 0, probes = 0;
  int? lastProbeMs, lastMigrationMs;
  String? lastFailure;
  final _clock = Stopwatch()..start();
  final _history = <Map<String, Object?>>[];
  final _socketGenerations = Expando<int>();

  String get route => identical(_active, _private)
      ? 'tailscale-websocket'
      : 'cloudflare-websocket';
  bool get hasPair => _pair != null;
  int generationOf(WebSocket socket) =>
      _socketGenerations[socket] ?? generation;
  Map<String, Object?> get routeDiagnostics => {
        'route': route,
        'transportGeneration': generation,
        'switches': switches,
        'probes': probes,
        'lastProbeMs': lastProbeMs,
        'lastMigrationMs': lastMigrationMs,
        'lastFailure': lastFailure,
        'history': _history.map((v) => Map<String, Object?>.of(v)).toList(),
      };

  @override
  bool get signedIn => !_ended && _active.signedIn;

  @override
  Future<Map<String, dynamic>> signIn(String username, String password) async {
    final value = await _public.signIn(username, password);
    try {
      final saved = await store.load();
      if (saved?.entry == entry) _pair = saved;
      await _observe(value['snapshot'], initial: true);
    } catch (_) {/* Public authentication remains fully usable. */}
    if (identical(_active, _public)) return value;
    return session();
  }

  /// The pinned address is not discovery: the pair was issued through the
  /// authenticated entry. Fresh challenges/host ID bind it across restarts.
  Future<Map<String, dynamic>?> restorePrivate() async {
    RemoteOwnerClient? candidate;
    final started = _clock.elapsedMilliseconds;
    try {
      final saved = await store.load();
      if (saved == null || saved.entry != entry || _ended) return null;
      _pair = saved;
      candidate = _privateClientFor(saved);
      final value =
          await candidate.resumePair(saved).timeout(const Duration(seconds: 3));
      if (_ended) {
        candidate.close();
        return null;
      }
      _private = candidate;
      _switch(candidate, 'paired_resume', started);
      candidate = null;
      _startProbes();
      return value;
    } catch (_) {
      return null;
    } finally {
      candidate?.close();
    }
  }

  void observeSnapshot(Map<String, dynamic> snapshot) {
    if (!_ended && !_enrolling) unawaited(_observe(snapshot));
  }

  Future<void> _observe(Object? snapshot, {bool initial = false}) async {
    if (_ended || _enrolling || snapshot is! Map) return;
    final descriptor = snapshot['privateRoute'];
    if (descriptor is! Map ||
        descriptor['version'] != 1 ||
        descriptor['hostId'] is! String) {
      return;
    }
    final origin = PrivatePair.parseOrigin(descriptor['origin'],
        loopbackForTesting: loopbackForTesting);
    if (origin == null) return;
    _enrolling = true;
    final started = _clock.elapsedMilliseconds;
    try {
      final existing = _pair;
      if (existing != null && existing.hostId == descriptor['hostId']) {
        // A port can change, but only an authenticated descriptor may update it.
        if (existing.origin != origin) {
          _pair = PrivatePair(
              entry: entry,
              hostId: existing.hostId,
              origin: origin,
              id: existing.id,
              key: existing.key);
          await store.save(_pair!);
        }
      } else if (allowEnrollment && _pair == null) {
        if (_enrollmentAttempt != null &&
            DateTime.now().difference(_enrollmentAttempt!) <
                const Duration(seconds: 30)) {
          return;
        }
        _enrollmentAttempt = DateTime.now();
        final grant = await _public.pairingTicket();
        if (_ended) return;
        if (grant['hostId'] != descriptor['hostId'] ||
            grant['origin'] != origin.toString() ||
            !['pairId', 'pairKey', 'ticket'].every((k) => grant[k] is String)) {
          return;
        }
        final pair = PrivatePair(
            entry: entry,
            hostId: grant['hostId'] as String,
            origin: origin,
            id: grant['pairId'] as String,
            key: grant['pairKey'] as String);
        // No private connection without a successful device-only Keychain save.
        await store.save(pair);
        if (_ended) {
          await store.clear();
          return;
        }
        final candidate = _privateClientFor(pair);
        try {
          await candidate.resumePair(pair, ticket: grant['ticket'] as String);
        } catch (_) {
          candidate.close();
          await store.clear();
          rethrow;
        }
        if (_ended) {
          candidate.close();
          return;
        }
        _pair = pair;
        _private = candidate;
        _switch(candidate, 'paired', started);
      }
      _startProbes();
      if (initial && _pair != null && identical(_active, _public)) {
        await probeNow(initial: true);
      }
    } catch (error) {
      lastFailure = _failureCode(error);
    } finally {
      _enrolling = false;
    }
  }

  void _startProbes() {
    if (_pair == null || _ended || _timer != null) return;
    _networkSubscription = networkChanges?.listen((_) {
      onNetworkChange?.call();
      unawaited(probeNow(force: true));
    });
    _timer = Timer.periodic(probeInterval, (_) => unawaited(probeNow()));
  }

  Future<void> probeNow({bool initial = false, bool force = false}) async {
    final pair = _pair;
    if (_ended || _probing || pair == null || _recovering != null) return;
    if (!initial && !force && _nextProbe?.isAfter(DateTime.now()) == true) {
      return;
    }
    _probing = true;
    final started = _clock.elapsedMilliseconds;
    ++probes;
    RemoteOwnerClient? candidate;
    try {
      if (identical(_active, _private)) {
        await _active.session().timeout(const Duration(seconds: 3));
        lastFailure = null;
        return;
      }
      candidate = _privateClientFor(pair);
      await candidate.resumePair(pair).timeout(const Duration(seconds: 3));
      if (_ended) return;
      _probeFailures = 0;
      lastFailure = null;
      _nextProbe = null;
      _healthySince ??= DateTime.now();
      ++_successes;
      final cooldown = _lastFailure == null ||
          DateTime.now().difference(_lastFailure!) >= switchbackDelay;
      if (initial ||
          (_successes >= 3 &&
              cooldown &&
              DateTime.now().difference(_healthySince!) >= switchbackDelay)) {
        _private?.close();
        _private = candidate;
        candidate = null;
        _switch(_private!, 'private_recovered', started);
      }
    } catch (error) {
      lastFailure = _failureCode(error);
      ++_probeFailures;
      _nextProbe =
          DateTime.now().add(probeInterval * (1 << _probeFailures.clamp(0, 4)));
      _healthySince = null;
      _successes = 0;
      if (!_ended && identical(_active, _private)) {
        await recover(generation,
            authentication:
                error is RemoteApiException && error.statusCode == 401);
      }
    } finally {
      candidate?.close();
      lastProbeMs = _clock.elapsedMilliseconds - started;
      _probing = false;
    }
  }

  void _switch(RemoteOwnerClient next, String reason, int started) {
    if (_ended || identical(_active, next)) return;
    _active = next;
    ++generation;
    ++switches;
    lastMigrationMs = _clock.elapsedMilliseconds - started;
    if (_history.length == 20) _history.removeAt(0);
    _history.add({
      'elapsedMs': _clock.elapsedMilliseconds,
      'route': route,
      'reason': reason,
      'generation': generation,
      'durationMs': lastMigrationMs
    });
    onMigration();
  }

  /// Only transport/authentication failures enter recovery. Business refusals
  /// (lease taken, stale state, audio busy) are returned without route hopping.
  static bool _recoverable(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is WebSocketException ||
      (error is RemoteApiException &&
          (error.statusCode == 401 ||
              error.statusCode == 502 ||
              error.statusCode == 504 ||
              (error.statusCode == 503 && error.code == 'request_failed') ||
              error.code == 'private_peer_denied' ||
              error.code == 'private_identity_unavailable'));

  static String _failureCode(Object error) {
    if (error is RemoteApiException) {
      const allowed = {
        'private_peer_denied',
        'private_identity_unavailable',
        'pairing_required',
        'invalid_pairing_ticket',
        'invalid_origin',
        'invalid_host'
      };
      return allowed.contains(error.code)
          ? error.code
          : 'http_${error.statusCode}';
    }
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'network_unreachable';
    return 'route_unavailable';
  }

  Future<bool> recover(int failedGeneration, {bool authentication = false}) {
    if (_ended || _pair == null) return Future.value(false);
    if (failedGeneration != generation) return Future.value(true);
    return _recovering ??=
        _recover(failedGeneration, authentication: authentication)
            .whenComplete(() => _recovering = null);
  }

  Future<bool> _recover(int failedGeneration,
      {bool authentication = false}) async {
    final pair = _pair!;
    final started = _clock.elapsedMilliseconds;
    final failed = _active;
    _lastFailure = DateTime.now();
    _healthySince = null;
    _successes = 0;
    RemoteOwnerClient? next;
    try {
      // Resolve the existing trusted entry again: a cached quick-tunnel hostname
      // can be obsolete. The pairing key is sent only to its approved HTTPS host.
      if (identical(failed, _private)) {
        if (authentication) {
          // Renew a healthy private path without depending on the tunnel.
          next = _privateClientFor(pair);
          try {
            await next.resumePair(pair).timeout(const Duration(seconds: 3));
          } catch (_) {
            next.close();
            next = null;
          }
        }
        if (next == null) {
          next = await reconnectPublic();
          await next.resumePair(pair);
        }
      } else {
        next = _privateClientFor(pair);
        try {
          await next.resumePair(pair).timeout(const Duration(seconds: 3));
        } catch (_) {
          next.close();
          next = await reconnectPublic();
          await next.resumePair(pair);
        }
      }
      if (_ended || generation != failedGeneration) return false;
      if (next.privatePair != null) {
        if (!identical(_private, failed)) _private?.close();
        _private = next;
      } else {
        if (!identical(_public, failed)) _public.close();
        _public = next;
      }
      _switch(next, 'transport_recovery', started);
      next = null;
      failed.close();
      return true;
    } catch (_) {
      return false;
    } finally {
      next?.close();
    }
  }

  Future<T> _run<T>(Future<T> Function(RemoteOwnerClient) operation) async {
    final before = generation;
    try {
      return await operation(_active);
    } catch (error) {
      if (!_recoverable(error) ||
          !await recover(before,
              authentication:
                  error is RemoteApiException && error.statusCode == 401)) {
        rethrow;
      }
      return operation(_active);
    }
  }

  @override
  Future<Map<String, dynamic>> session() => _run((c) => c.session());
  @override
  Future<String> lease({bool auto = false}) => _run((c) => c.lease(auto: auto));
  @override
  Future<Map<String, dynamic>> command(
      Map<String, dynamic> snapshot, String lease, String type,
      [Map<String, dynamic> payload = const {}]) {
    final envelope = commandEnvelope(snapshot, lease, type, payload);
    return _run((c) => c.sendCommand(envelope));
  }

  @override
  Future<WebSocket> openSocket(String purpose, {Map<String, Object?>? hello}) =>
      _run((c) async {
        final before = generation;
        final socket = await c.openSocket(purpose, hello: hello);
        _socketGenerations[socket] = before;
        return socket;
      });
  @override
  Future<void> signOut() async {
    try {
      await _run((c) => c.signOut());
    } finally {
      await store.clear();
      close();
    }
  }

  @override
  void close() {
    if (_ended) return;
    _ended = true;
    _timer?.cancel();
    unawaited(_networkSubscription?.cancel());
    _private?.close();
    _public.close();
    super.close();
  }
}
