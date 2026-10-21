import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/private_pair_store.dart';
import 'package:yinwei_player/remote/private_route.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_owner_client.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/routed_owner_client.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

import 'fake_output_source.dart';
import 'laptop_listen_controller_test.dart' show FakeListenOutput, until;

const ownerLogin = '26098681@example.test', nodeId = 'n-fixture-ipad';
const password = 'private-route-fixture-password';
const entry = 'https://entry.example.test/';

class MemoryPairStore implements PrivatePairStore {
  PrivatePair? value;
  @override
  Future<PrivatePair?> load() async => value;
  @override
  Future<void> save(PrivatePair pair) async => value = pair;
  @override
  Future<void> clear() async => value = null;
}

class TrackingTap extends FakeOutputSource {
  int owners = 0, maxOwners = 0, enableCalls = 0;
  @override
  void setEnabled(bool value) {
    if (value) {
      owners++;
      enableCalls++;
    } else if (enabled) {
      owners--;
    }
    if (owners > maxOwners) maxOwners = owners;
    super.setEnabled(value);
  }
}

class SlowOutput extends FakeListenOutput {
  int resetSerial = 0, staleWrites = 0;
  @override
  Future<void> newStream(int sampleRate) async {
    ++resetSerial;
    await super.newStream(sampleRate);
  }

  @override
  Future<bool> write(Uint8List packet) async {
    final before = resetSerial;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (before != resetSerial) ++staleWrites;
    return super.write(packet);
  }
}

class ReplyLostClient extends RemoteOwnerClient {
  ReplyLostClient(super.pair, this.loseReply)
      : super.privateRoute(allowLoopbackForTests: true);
  final bool Function() loseReply;
  @override
  Future<Map<String, dynamic>> sendCommand(
      Map<String, dynamic> envelope) async {
    final result = await super.sendCommand(envelope);
    if (loseReply()) throw const SocketException('synthetic lost reply');
    return result;
  }
}

class Fixture {
  late RemoteGateway gateway;
  late RemoteAuth auth;
  late EngineController engine;
  late AppSessionCoordinator coordinator;
  late PrivateRouteHost host;
  final tap = TrackingTap();
  final media = <String>[];
  DateTime now = DateTime.now();
  TailscalePeer? peer = const TailscalePeer(ownerLogin, nodeId);
  int lookups = 0;

  static Future<Fixture> create({bool rotation = false, File? pairFile}) async {
    final f = Fixture();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    f.auth = RemoteAuth(
        RemoteAccount(
            username: 'owner',
            salt: base64UrlEncode(salt),
            hash: base64UrlEncode(await key.extractBytes()),
            iterations: 10),
        now: () => f.now);
    f.engine = EngineController(engine: MockEngine());
    f.coordinator = AppSessionCoordinator(
        controller: f.engine,
        spatial: SpatialRuntimeAdapter()..bootstrap(f.engine.params),
        nativeBackend: true,
        liveRunning: () => false,
        libraryList: (_) async =>
            {'available': true, 'revision': 'r1', 'rows': []},
        liveMedia: (action) async => f.media.add(action));
    f.host = PrivateRouteHost(
        file: pairFile,
        config: PrivateRouteConfig.loopbackForTesting(
            ownerLogin: ownerLogin, nodeId: nodeId),
        auth: f.auth,
        now: () => f.now,
        lookup: (_) async {
          f.lookups++;
          return f.peer;
        });
    f.gateway = RemoteGateway(
        auth: f.auth,
        coordinator: f.coordinator,
        privateRoute: f.host,
        audioTap: f.tap,
        allowOriginRotation: rotation,
        loadAsset: (_) async =>
            Uint8List.fromList(utf8.encode('LOGIN_CSRF_TOKEN')));
    await f.gateway.start(
        publicOrigin:
            rotation ? Uri.parse('https://old.trycloudflare.com') : null);
    addTearDown(() async {
      await f.gateway.close();
      f.engine.dispose();
    });
    return f;
  }

  RemoteOwnerClient publicClient() =>
      RemoteOwnerClient(origin: gateway.origin, allowLoopbackForTests: true);

  Future<({PrivatePair pair, String ticket})> grant(
      RemoteOwnerClient client) async {
    final value = await client.pairingTicket();
    return (
      pair: PrivatePair(
          entry: entry,
          hostId: value['hostId'] as String,
          origin: Uri.parse(value['origin'] as String),
          id: value['pairId'] as String,
          key: value['pairKey'] as String),
      ticket: value['ticket'] as String
    );
  }

  Future<({RemoteOwnerClient client, PrivatePair pair})> enroll() async {
    final public = publicClient();
    await public.signIn('owner', password);
    final grant = await this.grant(public);
    final client =
        RemoteOwnerClient.privateRoute(grant.pair, allowLoopbackForTests: true);
    await client.resumePair(grant.pair, ticket: grant.ticket);
    addTearDown(() {
      public.close();
      client.close();
    });
    return (client: client, pair: grant.pair);
  }

  Future<({int status, Map<String, dynamic> body})> request(String path,
      {bool private = true,
      String? cookie,
      String? csrf,
      Map<String, String> headers = const {},
      Map<String, dynamic>? body}) async {
    final http = HttpClient();
    try {
      final origin = private ? host.origin! : gateway.origin;
      final address =
          private ? origin : Uri.parse('http://127.0.0.1:${gateway.port}');
      final request = await http.openUrl(
          body == null ? 'GET' : 'POST', address.resolve(path));
      request.headers.set('Host', origin.authority);
      request.headers.set('Origin', origin.toString());
      if (cookie != null) request.headers.set('Cookie', cookie);
      if (csrf != null) request.headers.set('X-CSRF-Token', csrf);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      return (
        status: response.statusCode,
        body: jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>
      );
    } finally {
      http.close(force: true);
    }
  }
}

void main() {
  Future<Directory> temporaryDirectory() async {
    final root =
        Directory('${Directory.current.path}/.dart_tool/private-route-tests');
    await root.create(recursive: true);
    final directory = await root.createTemp('case-');
    addTearDown(() async {
      final resolved = await directory.resolveSymbolicLinks();
      expect(
          resolved,
          startsWith(
              '${await root.resolveSymbolicLinks()}${Platform.pathSeparator}'));
      await directory.delete(recursive: true);
    });
    return directory;
  }

  test('bind retries only its configured interface and stops on close',
      () async {
    final f = await Fixture.create();
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = blocker.port;
    final host = PrivateRouteHost(
        auth: f.auth,
        config: PrivateRouteConfig.loopbackForTesting(
            ownerLogin: ownerLogin, nodeId: nodeId, port: port),
        lookup: (_) async => f.peer,
        retryBase: const Duration(milliseconds: 20));
    await host.start((request) async {
      await request.response.close();
    });
    expect(host.origin, isNull);
    await blocker.close(force: true);
    await until(() => host.origin != null);
    expect(host.origin!.host, '127.0.0.1');
    expect(host.origin!.port, port);
    await host.close();
    final available = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await available.close(force: true);
  });

  test(
      'an existing unrelated JSON file is never overwritten by pairing storage',
      () async {
    final directory = await temporaryDirectory();
    final file = File('${directory.path}/owner.json');
    const original = '{"version":1,"owner":{"username":"fixture"}}';
    await file.writeAsString(original);
    final f = await Fixture.create(pairFile: file);
    expect(f.host.origin, isNull);
    expect(await file.readAsString(), original);
    final public = f.publicClient();
    expect((await public.signIn('owner', password))['csrf'], isA<String>());
    public.close();
  });

  test('pair persistence contains only a hash; revocation survives reopening',
      () async {
    final directory = await temporaryDirectory();
    final file = File('${directory.path}/pairs.json');
    final f = await Fixture.create(pairFile: file);
    final enrolled = await f.enroll();
    final text = await file.readAsString();
    expect(text, isNot(contains(enrolled.pair.key)));
    await f.host.close();
    PrivateRouteHost reopened() => PrivateRouteHost(
        auth: f.auth,
        config: PrivateRouteConfig.loopbackForTesting(
            ownerLogin: ownerLogin, nodeId: nodeId),
        lookup: (_) async => f.peer,
        file: file);
    final host = reopened();
    await host.start((request) async {
      await request.response.close();
    });
    expect(host.hostId, enrolled.pair.hostId);
    expect(host.verifyKey(enrolled.pair.id, enrolled.pair.key), isA<String>());
    await host.revoke();
    await host.close();
    final afterRevoke = reopened();
    await afterRevoke.start((request) async {
      await request.response.close();
    });
    expect(() => afterRevoke.verifyKey(enrolled.pair.id, enrolled.pair.key),
        throwsA(isA<RemoteFailure>()));
    await afterRevoke.close();
  });

  test(
      'whois failure closes an established private stream; public stays available',
      () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    final audio = await enrolled.client.openSocket('audio');
    final done = Completer<void>();
    audio.listen((_) {}, onDone: () => done.complete());
    await until(() => f.tap.enabled);
    f.peer = null;
    f.now = f.now.add(const Duration(seconds: 3));
    await done.future.timeout(const Duration(seconds: 4));
    expect(f.tap.enabled, isFalse);
    final public = f.publicClient();
    await public.resumePair(enrolled.pair);
    expect(public.signedIn, isTrue);
    public.close();
  });

  test(
      'public owner revoke-devices invalidates pairing as well as route cookies',
      () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    final owner = await f.auth.signin('owner', password);
    final result = await f.request('/remote/api/owner/revoke-devices',
        private: false,
        cookie: 'yinwei_local=${owner.token}',
        csrf: owner.session.csrf,
        body: {});
    expect(result.status, 200);
    await expectLater(enrolled.client.resumePair(enrolled.pair),
        throwsA(isA<RemoteApiException>()));
  });

  test('private requests cannot replace Host or Origin with forwarded headers',
      () async {
    final f = await Fixture.create();
    for (final headers in [
      {
        'Host': 'attacker.example',
        'X-Forwarded-Host': f.host.origin!.authority
      },
      {'Origin': 'https://attacker.example', 'X-Forwarded-Proto': 'https'},
    ]) {
      expect(
          (await f.request('/remote/api/private/resume',
                  body: {}, headers: headers))
              .status,
          403);
    }
  });
  test('feature is default off; production binding cannot be widened',
      () async {
    final f = await Fixture.create();
    expect(PrivateRouteHost.fromEnvironment({}, f.auth), isNull);
    final env = {
      'YINWEI_TAILSCALE_ENABLED': '1',
      'YINWEI_TAILSCALE_OWNER_LOGIN': ownerLogin,
      'YINWEI_TAILSCALE_IPAD_NODE_ID': nodeId,
      'YINWEI_TAILSCALE_EXE':
          File('${Directory.systemTemp.path}/tailscale-test').absolute.path,
      'LOCALAPPDATA': Directory.current.absolute.path
    };
    final normal = PrivateRouteHost.fromEnvironment(env, f.auth)!;
    expect(normal.file!.path, endsWith('Yinwei/remote/private-route.json'));
    await normal.close();
    for (final unsafe in [
      'outputs/pair.json',
      'assets/pair.json',
      'deployment.json'
    ]) {
      expect(
          () => PrivateRouteHost.fromEnvironment({
                ...env,
                'YINWEI_TAILSCALE_PAIR_FILE': File(unsafe).absolute.path
              }, f.auth),
          throwsFormatException);
    }
    final config = PrivateRouteConfig(ownerLogin: ownerLogin, nodeId: nodeId);
    expect(config.address.address, privateRouteAddress);
    expect(() => PrivateRouteConfig(ownerLogin: '26098681@', nodeId: nodeId),
        throwsFormatException);
    for (final bad in [
      'http://0.0.0.0:8443',
      'http://192.168.1.2:8443',
      'http://100.80.104.77:8443/path',
      'http://100.80.104.77:8443?key=x'
    ]) {
      expect(PrivatePair.parseOrigin(bad), isNull);
    }
    expect(
        () => RemoteOwnerClient(origin: Uri.parse('http://100.80.104.77:8443')),
        throwsArgumentError);
  });

  for (final denied in [
    const TailscalePeer('26071589@example.test', nodeId),
    const TailscalePeer(ownerLogin, 'n-other-device'),
    const TailscalePeer(ownerLogin, nodeId, tagged: true),
    null,
  ]) {
    test('private peer gate rejects ${denied?.login}/${denied?.nodeId}',
        () async {
      final f = await Fixture.create();
      f.peer = denied;
      final response = await f.request('/remote/api/session', headers: {
        'X-Forwarded-For': '100.78.238.127',
        'Tailscale-User-Login': ownerLogin,
        'X-Yinwei-Host-Token': f.gateway.hostToken,
      });
      expect(response.status, denied == null ? 503 : 403);
      // Failure on the private interface never prevents public sign-in.
      final public = f.publicClient();
      expect((await public.signIn('owner', password))['csrf'], isA<String>());
      public.close();
    });
  }

  test(
      'unpaired clients fail and private endpoint allowlist excludes internal/assets/capture',
      () async {
    final f = await Fixture.create();
    expect((await f.request('/remote/api/session')).status, 401);
    for (final path in [
      '/remote/internal/readiness',
      '/remote/internal/origin',
      '/remote/signin',
      '/remote/api/auth/signin',
      '/remote/ws/transform',
      '/remote/api/capture-probe',
      '/remote/guest',
      '/remote/app'
    ]) {
      expect(
          (await f.request(path, headers: {
            'X-Yinwei-Host-Token': f.gateway.hostToken,
          }))
              .status,
          404,
          reason: path);
    }
    expect(f.lookups, 1); // Short positive cache; no per-frame whois processes.
  });

  test(
      'private catalog endpoint reaches owner auth instead of allowlist refusal',
      () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    final response = await f.request('/remote/api/commands', headers: {
      'X-Yinwei-Pair-Id': enrolled.pair.id,
      'X-Yinwei-Pair-Key': enrolled.pair.key,
    }, body: {});
    // Pair possession grants private routing, not an owner session or CSRF.
    expect(response.status, 401);
  });

  test('paired private owner can browse without taking control', () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    final result =
        await enrolled.client.libraryList(f.coordinator.snapshot(), {});
    expect(result['available'], isTrue);
    expect(result['rows'], isEmpty);
    expect(f.coordinator.snapshot(device: enrolled.pair.id)['controlOwned'],
        isFalse);
    f.peer = null;
    f.now = f.now.add(const Duration(seconds: 3));
    await expectLater(
        enrolled.client.libraryList(f.coordinator.snapshot(), {}),
        throwsA(isA<RemoteApiException>()
            .having((e) => e.code, 'code', 'private_identity_unavailable')));
  });

  test('pair tickets expire, are single-use, and cannot be redeemed publicly',
      () async {
    final f = await Fixture.create();
    final public = f.publicClient();
    await public.signIn('owner', password);
    final first = await f.grant(public);
    f.now = f.now.add(const Duration(seconds: 31));
    final private =
        RemoteOwnerClient.privateRoute(first.pair, allowLoopbackForTests: true);
    await expectLater(
        private.resumePair(first.pair, ticket: first.ticket),
        throwsA(isA<RemoteApiException>()
            .having((e) => e.code, 'code', 'invalid_pairing_ticket')));
    private.close();
    final second = await f.grant(public);
    final client = RemoteOwnerClient.privateRoute(second.pair,
        allowLoopbackForTests: true);
    await client.resumePair(second.pair, ticket: second.ticket);
    await expectLater(client.resumePair(second.pair, ticket: second.ticket),
        throwsA(isA<RemoteApiException>()));
    expect(
        (await f.request('/remote/api/private/pair', private: false, body: {
          'ticket': second.ticket
        }, headers: {
          'X-Yinwei-Pair-Id': second.pair.id,
          'X-Yinwei-Pair-Key': second.pair.key,
        }))
            .status,
        401);
    client.close();
    public.close();
  });

  test(
      'private connections verify key as well as node, with bounded identity cache',
      () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    expect((await enrolled.client.session())['snapshot'], isA<Map>());
    final wrong = PrivatePair(
        entry: entry,
        hostId: enrolled.pair.hostId,
        origin: enrolled.pair.origin,
        id: enrolled.pair.id,
        key: remoteSecret());
    final client =
        RemoteOwnerClient.privateRoute(wrong, allowLoopbackForTests: true);
    await expectLater(
        client.resumePair(wrong), throwsA(isA<RemoteApiException>()));
    client.close();
    f.peer = null;
    f.now = f.now.add(const Duration(seconds: 3));
    await expectLater(
        enrolled.client.session(),
        throwsA(isA<RemoteApiException>()
            .having((e) => e.code, 'code', 'private_identity_unavailable')));
  });

  test('revocation rejects a stored key on both routes and terminates streams',
      () async {
    final f = await Fixture.create();
    final enrolled = await f.enroll();
    final audio = await enrolled.client.openSocket('audio');
    final done = Completer<void>();
    audio.listen((_) {}, onDone: () => done.complete());
    await until(() => f.tap.enabled);
    await f.host.revoke();
    await done.future.timeout(const Duration(seconds: 4));
    expect(f.tap.enabled, isFalse);
    await expectLater(enrolled.client.resumePair(enrolled.pair),
        throwsA(isA<RemoteApiException>()));
    final public = f.publicClient();
    await expectLater(
        public.resumePair(enrolled.pair), throwsA(isA<RemoteApiException>()));
    public.close();
  });

  test(
      'public-origin rotation preserves private audio, lease and command authority',
      () async {
    final f = await Fixture.create(rotation: true);
    final login = await f.auth.signin('owner', password);
    final grant = f.host.issueTicket(login.session);
    final pair = PrivatePair(
        entry: entry,
        hostId: f.host.hostId,
        origin: f.host.origin!,
        id: grant['pairId'] as String,
        key: grant['pairKey'] as String);
    final client =
        RemoteOwnerClient.privateRoute(pair, allowLoopbackForTests: true);
    await client.resumePair(pair, ticket: grant['ticket'] as String);
    final lease = await client.lease();
    final socket = await client.openSocket('audio');
    var packets = 0;
    final subscription = socket.listen((message) {
      if (message is List<int>) {
        ++packets;
        socket.add(jsonEncode({
          'ack': ByteData.sublistView(Uint8List.fromList(message))
              .getUint64(16, Endian.little)
        }));
      }
    });
    await until(() => packets > 2);
    expect(
        (await f.request('/remote/internal/origin', private: false, headers: {
          'X-Yinwei-Host-Token': f.gateway.hostToken
        }, body: {
          'hostSessionId': f.coordinator.hostSessionId,
          'origin': 'https://new.trycloudflare.com'
        }))
            .status,
        200);
    final before = packets;
    await until(() => packets > before + 2);
    final state = (await client.session())['snapshot'] as Map<String, dynamic>;
    expect((await client.command(state, lease, 'media.next'))['status'],
        'native_applied');
    expect(f.media, ['next']);
    await subscription.cancel();
    await socket.close();
    client.close();
  });

  test(
      'network switch falls back and returns with hysteresis, one tap owner and no stale writes',
      () async {
    final f = await Fixture.create();
    final store = MemoryPairStore();
    final output = SlowOutput();
    final listen = LaptopListenController(
        output: output,
        pairStore: store,
        resolveEntry: (_) async => f.gateway.origin,
        clientFor: (_) => f.publicClient(),
        privateClientFor: (pair) =>
            RemoteOwnerClient.privateRoute(pair, allowLoopbackForTests: true),
        privateLoopbackForTesting: true,
        routeProbeInterval: const Duration(milliseconds: 30),
        routeSwitchbackDelay: const Duration(milliseconds: 140),
        retryDelay: const Duration(milliseconds: 20));
    addTearDown(() async {
      listen.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await listen.signIn(entry, 'owner', password);
    await until(() => listen.connected);
    await listen.startListening();
    await until(() => output.written > 2);
    Map network() => listen.audioDiagnostics()['network'] as Map;
    expect(network()['route'], 'tailscale-websocket');
    expect(output.privateRoutes.last, isTrue);
    expect(listen.hasControl, isTrue);
    f.peer = null;
    f.now = f.now.add(const Duration(seconds: 3));
    await until(() => network()['route'] == 'cloudflare-websocket');
    final before = output.written;
    await until(() => output.written > before + 2 && listen.connected);
    expect(output.privateRoutes.last, isFalse);
    expect(listen.hasControl, isTrue);
    f.peer = const TailscalePeer(ownerLogin, nodeId);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(network()['route'], 'cloudflare-websocket');
    await until(() => network()['route'] == 'tailscale-websocket');
    await until(() => output.privateRoutes.last);
    await until(() => output.written > before + 5);
    expect(f.tap.maxOwners, 1);
    expect(output.staleWrites, 0);
    expect(network()['switches'], greaterThanOrEqualTo(3));
    expect(jsonEncode(listen.audioDiagnostics()),
        isNot(contains(store.value!.key)));
  });

  test(
      'lost command reply retries identical ID over fallback and executes once',
      () async {
    final f = await Fixture.create();
    var lose = false;
    final public = f.publicClient();
    final routed = RoutedOwnerClient(
        publicClient: public,
        entry: entry,
        store: MemoryPairStore(),
        reconnectPublic: () async => f.publicClient(),
        onMigration: () {},
        loopbackForTesting: true,
        privateClientFor: (pair) => ReplyLostClient(pair, () {
              final result = lose;
              lose = false;
              return result;
            }));
    addTearDown(routed.close);
    await routed.signIn('owner', password);
    final lease = await routed.lease();
    final state = (await routed.session())['snapshot'] as Map<String, dynamic>;
    lose = true;
    await routed.command(state, lease, 'media.next');
    expect(f.media, ['next']);
    expect(routed.route, 'cloudflare-websocket');
    await expectLater(routed.command(state, 'wrong-lease', 'media.next'),
        throwsA(isA<RemoteApiException>()));
    expect(routed.route,
        'cloudflare-websocket'); // A refusal is not a network failure.
    expect(f.media, ['next']);
  });

  test('network path changes wake recovery without waiting for the probe timer',
      () async {
    final f = await Fixture.create();
    final changes = StreamController<void>.broadcast();
    final routed = RoutedOwnerClient(
        publicClient: f.publicClient(),
        entry: entry,
        store: MemoryPairStore(),
        reconnectPublic: () async => f.publicClient(),
        onMigration: () {},
        loopbackForTesting: true,
        networkChanges: changes.stream,
        probeInterval: const Duration(days: 1),
        privateClientFor: (pair) =>
            RemoteOwnerClient.privateRoute(pair, allowLoopbackForTests: true));
    addTearDown(() async {
      routed.close();
      await changes.close();
    });
    await routed.signIn('owner', password);
    expect(routed.route, 'tailscale-websocket');
    f.peer = null;
    f.now = f.now.add(const Duration(seconds: 3));
    changes.add(null);
    await until(() => routed.route == 'cloudflare-websocket');
    expect(routed.probes, greaterThan(0));
  });

  test('saved-login recovery never silently enrolls an unpaired device',
      () async {
    final f = await Fixture.create();
    final store = MemoryPairStore();
    final routed = RoutedOwnerClient(
        publicClient: f.publicClient(),
        entry: entry,
        store: store,
        reconnectPublic: () async => f.publicClient(),
        onMigration: () {},
        loopbackForTesting: true,
        allowEnrollment: false);
    addTearDown(routed.close);
    await routed.signIn('owner', password);
    expect(routed.route, 'cloudflare-websocket');
    expect(store.value, isNull);
    expect(f.lookups, 0);
  });

  test(
      'expired private cookie renews with the pair key while Cloudflare is unavailable',
      () async {
    final f = await Fixture.create();
    final routed = RoutedOwnerClient(
        publicClient: f.publicClient(),
        entry: entry,
        store: MemoryPairStore(),
        reconnectPublic: () async =>
            throw const SocketException('public unavailable'),
        onMigration: () {},
        loopbackForTesting: true,
        privateClientFor: (pair) =>
            RemoteOwnerClient.privateRoute(pair, allowLoopbackForTests: true));
    addTearDown(routed.close);
    await routed.signIn('owner', password);
    f.now = f.now.add(const Duration(hours: 9));
    expect((await routed.session())['snapshot'], isA<Map>());
    expect(routed.route, 'tailscale-websocket');
    expect(routed.generation, greaterThanOrEqualTo(2));
  });

  test('a revoked public session cannot redeem its outstanding pairing ticket',
      () async {
    final f = await Fixture.create();
    final login = await f.auth.signin('owner', password);
    final grant = f.host.issueTicket(login.session);
    f.auth.revoke(login.session);
    await expectLater(
        f.host.redeem(grant['ticket'] as String, grant['pairId'] as String),
        throwsA(isA<RemoteFailure>()));
    expect(f.host.hasPair(grant['pairId'] as String), isFalse);
  });

  test('concurrent enrollment and revocation cannot resurrect a pairing key',
      () async {
    final f = await Fixture.create();
    final login = await f.auth.signin('owner', password);
    final grant = f.host.issueTicket(login.session);
    final redeem =
        f.host.redeem(grant['ticket'] as String, grant['pairId'] as String);
    final revoke = f.host.revoke();
    await expectLater(redeem, throwsA(isA<RemoteFailure>()));
    await revoke;
    expect(
        () => f.host
            .verifyKey(grant['pairId'] as String, grant['pairKey'] as String),
        throwsA(isA<RemoteFailure>()));
  });
}
