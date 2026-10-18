import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_transform.dart';
import 'package:yinwei_player/remote/remote_transform_client.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

import 'transform_test_support.dart';

void main() {
  late RemoteGateway gateway;
  late RemoteAuth auth;
  late EngineController controller;
  late SyntheticTransformAdapter adapter;
  late DateTime authTime;
  final clients = <RemoteTransformClient>[];
  const password = 'generated-fixture-password';

  Future<void> setupFixture({Uri? publicOrigin}) async {
    authTime = DateTime.now();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    auth = RemoteAuth(
        RemoteAccount(
            username: 'fixture-owner',
            salt: base64UrlEncode(salt),
            hash: base64UrlEncode(await key.extractBytes()),
            iterations: 10),
        now: () => authTime);
    controller = EngineController(engine: MockEngine());
    adapter = SyntheticTransformAdapter();
    gateway = RemoteGateway(
        auth: auth,
        allowOriginRotation: publicOrigin != null,
        transformAdapter: adapter,
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => false),
        loadAsset: (_) async =>
            Uint8List.fromList(utf8.encode('<html></html>')));
    await gateway.start(publicOrigin: publicOrigin);
  }

  setUp(() => setupFixture());
  tearDown(() async {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
    await gateway.close();
    controller.dispose();
  });

  Future<RemoteTransformClient> client(
      {void Function(Uint8List)? output}) async {
    final value = RemoteTransformClient(
        origin: gateway.origin,
        allowLoopbackForTests: true,
        onOutput: output ?? (_) {});
    clients.add(value);
    await value.signIn('fixture-owner', password);
    await value.start();
    return value;
  }

  Future<({WebSocket socket, StreamIterator<dynamic> events, int epoch})> raw(
      {String purpose = 'transform',
      bool authenticate = true,
      String? reusedTicket}) async {
    final login = await auth.signin('fixture-owner', password);
    final ticket = reusedTicket ?? auth.ticket(login.session, purpose);
    final socket = await WebSocket.connect(
        'ws://127.0.0.1:${gateway.port}/remote/ws/transform',
        headers: {
          'Origin': gateway.origin.toString(),
          'Host': gateway.origin.authority,
          'Cookie':
              '${gateway.origin.scheme == 'https' ? '__Host-yinwei' : 'yinwei_local'}=${login.token}',
        },
        compression: CompressionOptions.compressionOff);
    final events = StreamIterator<dynamic>(socket);
    if (!authenticate) return (socket: socket, events: events, epoch: 0);
    socket.add(jsonEncode({'ticket': ticket}));
    final ready = await events.moveNext().timeout(const Duration(seconds: 3));
    return (
      socket: socket,
      events: events,
      epoch: ready
          ? (jsonDecode(events.current as String) as Map)['epoch'] as int
          : 0
    );
  }

  Future<void> eventually(bool Function() check) async {
    for (var i = 0; i < 100; ++i) {
      if (check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(check(), true);
  }

  Uint8List input(int epoch,
          {int sequence = 1, int frame = 0, bool gap = true}) =>
      RemoteInputFrame.encode(
          epoch: epoch,
          sequence: sequence,
          firstFrame: frame,
          pcm: syntheticInput(),
          discontinuous: gap);

  test('native client signs in and roundtrips exact generated stereo samples',
      () async {
    final received = Completer<Uint8List>();
    final value = await client(output: received.complete);
    expect(value.trySend(syntheticInput()), true);
    final packet = await received.future.timeout(const Duration(seconds: 3));
    final data = ByteData.sublistView(packet);
    for (var i = 0; i < 960; ++i) {
      expect(data.getFloat32(56 + i * 4, Endian.little),
          syntheticInput()[i] / 32768);
    }
    expect(data.getUint32(40, Endian.little), 0);
    await eventually(() => value.accepted == 1);
    expect(controller.hasOpenedFile, false);
    expect(controller.playing, false);
    expect(adapter.gaps, [true]);
  });

  test('client drops newest instead of retaining more than one input window',
      () async {
    final value = await client();
    const credit = RemoteTransformFlow.inputCredit;
    for (var i = 0; i < credit; ++i) {
      expect(value.trySend(syntheticInput()), true);
    }
    expect(value.trySend(syntheticInput()), false);
    expect(value.pendingCount, credit);
    expect(value.dropped, 1);
    await eventually(() => value.pendingCount == 0);
    await eventually(() => adapter.pushes == credit);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(value.trySend(syntheticInput()), true);
    await eventually(() => adapter.pushes == credit + 1);
    expect(adapter.gaps.last, true);
  });

  test('stop flushes and deliberate reconnect owns a fresh epoch', () async {
    adapter.holdOutput = true;
    final value = await client();
    final epoch = value.epoch;
    value.trySend(syntheticInput());
    await eventually(() => adapter.queued == 1);
    value.stop();
    await eventually(() => adapter.stops == 1);
    expect(adapter.queued, 0);
    expect(value.trySend(syntheticInput()), false);
    await value.start();
    expect(value.epoch, isNot(epoch));
    expect(value.connected, true);
    value.trySend(syntheticInput());
    await eventually(() => adapter.queued == 1);
    expect(adapter.starts, 2);
  });

  test('signout revokes and flushes only remote adapter', () async {
    adapter.holdOutput = true;
    final value = await client();
    value.trySend(syntheticInput());
    await eventually(() => adapter.queued == 1);
    await value.signOut();
    await eventually(() => adapter.stops == 1);
    expect(adapter.queued, 0);
    await expectLater(value.start(), throwsStateError);
    expect(controller.hasOpenedFile, false);
  });

  test('owner revocation and expiry close the live socket and clear queued PCM',
      () async {
    adapter.holdOutput = true;
    final value = await client();
    value.trySend(syntheticInput());
    await eventually(() => adapter.queued == 1);
    for (final session in auth.sessions) {
      auth.revoke(session);
    }
    await eventually(() => !value.connected && adapter.stops == 1);
    expect(adapter.queued, 0);
    final next = await client();
    authTime = authTime.add(const Duration(hours: 9));
    await eventually(() => !next.connected && adapter.stops == 2);
  });

  test('second authenticated transform source cannot take the first lease',
      () async {
    final first = await client();
    final second = RemoteTransformClient(
        origin: gateway.origin, allowLoopbackForTests: true, onOutput: (_) {});
    clients.add(second);
    await second.signIn('fixture-owner', password);
    await expectLater(second.start(), throwsA(isA<HttpException>()));
    expect(first.connected, true);
    expect(adapter.starts, 1);
  });

  test('binary media cannot reach ingress before ticket authentication',
      () async {
    final stream = await raw(authenticate: false);
    stream.socket.add(input(1));
    expect(await stream.events.moveNext().timeout(const Duration(seconds: 3)),
        false);
    expect(adapter.starts, 0);
    expect(adapter.pushes, 0);
    await stream.events.cancel();
  });

  test('wrong-purpose ticket never starts adapter', () async {
    final stream = await raw(purpose: 'events');
    expect(stream.epoch, 0);
    expect(stream.socket.closeReason, 'invalid_ticket');
    expect(adapter.starts, 0);
    await stream.events.cancel();
  });

  test('transform tickets expire, bind device and cannot be reused', () async {
    final first = await auth.signin('fixture-owner', password);
    final second = await auth.signin('fixture-owner', password);
    final wrong = auth.ticket(first.session, 'transform');
    expect(auth.consumeTicket(second.session, wrong, 'transform'), false);
    expect(auth.consumeTicket(first.session, wrong, 'transform'), false);
    final expired = auth.ticket(first.session, 'transform');
    authTime = authTime.add(const Duration(seconds: 21));
    expect(auth.consumeTicket(first.session, expired, 'transform'), false);
    final fresh = auth.ticket(first.session, 'transform');
    expect(auth.consumeTicket(first.session, fresh, 'transform'), true);
    expect(auth.consumeTicket(first.session, fresh, 'transform'), false);
  });

  for (final kind in ['oldEpoch', 'replay', 'oversized', 'badAck']) {
    test('$kind ends session and flushes its queue', () async {
      adapter.holdOutput = true;
      final stream = await raw();
      if (kind == 'replay') {
        stream.socket.add(input(stream.epoch));
        expect(await stream.events.moveNext(), true);
      }
      stream.socket.add(switch (kind) {
        'oldEpoch' => input(stream.epoch - 1),
        'replay' => input(stream.epoch),
        'oversized' => Uint8List(2049),
        _ => jsonEncode({'ack': 999}),
      });
      while (
          await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
      expect(adapter.stops, 1);
      expect(adapter.queued, 0);
      await stream.events.cancel();
    });
  }

  test('excess input rate is rejected without growing the adapter queue',
      () async {
    adapter.holdOutput = true;
    final stream = await raw();
    for (var i = 1; i <= 100; ++i) {
      stream.socket.add(input(stream.epoch, sequence: i, frame: (i - 1) * 480));
    }
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeReason, 'input_rate_limited');
    expect(adapter.peakQueued, lessThanOrEqualTo(8));
    expect(adapter.queued, 0);
    await stream.events.cancel();
  });

  test('failed adapter start cleans up partial allocation', () async {
    adapter.failStart = true;
    final stream = await raw();
    expect(stream.epoch, 0);
    expect(adapter.stops, 1);
    expect(adapter.started, false);
    await stream.events.cancel();
  });

  test('nonfinite output ends stream before sending corrupt audio', () async {
    adapter.corruptOutput = true;
    final value = await client(output: (_) => fail('Corrupt audio delivered'));
    value.trySend(syntheticInput());
    await eventually(() => !value.connected);
    expect(adapter.stops, 1);
  });

  test('silent input source without new chunks reaches bounded idle deadline',
      () async {
    final value = await client();
    await Future<void>.delayed(const Duration(milliseconds: 5300));
    expect(value.connected, false);
    expect(adapter.stops, 1);
  });

  test('public native transport requires HTTPS with no URL credentials', () {
    for (final url in [
      'http://yinwei.example',
      'https://u:p@yinwei.example',
      'https://yinwei.example/path',
      'https://yinwei.example/?token=x'
    ]) {
      expect(
          () => RemoteTransformClient(origin: Uri.parse(url), onOutput: (_) {}),
          throwsArgumentError);
    }
  });

  test('unavailable native adapter keeps transform activation closed',
      () async {
    adapter.available = false;
    final value = RemoteTransformClient(
        origin: gateway.origin, allowLoopbackForTests: true, onOutput: (_) {});
    clients.add(value);
    await value.signIn('fixture-owner', password);
    await expectLater(value.start(), throwsA(isA<HttpException>()));
    expect(adapter.starts, 0);
  });

  test('origin rotation flushes transform and old sessions cannot resume',
      () async {
    await gateway.close();
    controller.dispose();
    await setupFixture(
        publicOrigin: Uri.parse('https://r1-old.trycloudflare.com'));
    adapter.holdOutput = true;
    final stream = await raw();
    stream.socket.add(input(stream.epoch));
    expect(await stream.events.moveNext(), true);
    final oldEpoch = stream.epoch;
    final http = HttpClient();
    try {
      final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:${gateway.port}/remote/internal/origin'));
      request.headers
        ..set('Host', gateway.origin.authority)
        ..set('Origin', gateway.origin.toString())
        ..set('X-Yinwei-Host-Token', gateway.hostToken)
        ..contentType = ContentType.json;
      request.write(jsonEncode({
        'origin': 'https://r1-new.trycloudflare.com',
        'hostSessionId': gateway.coordinator.hostSessionId
      }));
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      while (
          await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
      expect(adapter.queued, 0);
      expect(adapter.stops, 1);
      expect(auth.sessions, isEmpty);
      final fresh = await raw();
      expect(fresh.epoch, isNot(oldEpoch));
      fresh.socket.add(input(oldEpoch));
      while (
          await fresh.events.moveNext().timeout(const Duration(seconds: 3))) {}
      expect(adapter.stops, 2);
      await fresh.events.cancel();
    } finally {
      http.close(force: true);
      await stream.events.cancel();
    }
  });

  test('output credit stays bounded when client stops acknowledging audio',
      () async {
    final stream = await raw();
    var output = 0;
    // Drain without ACKs so the gateway sends at most one output window.
    const credit = RemoteTransformFlow.outputCredit;
    final drain = () async {
      while (await stream.events.moveNext()) {
        if (stream.events.current is List<int>) ++output;
      }
    }();
    for (var i = 1; i <= credit + 16; ++i) {
      stream.socket.add(input(stream.epoch, sequence: i, frame: (i - 1) * 480));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(output, credit);
    expect(adapter.queued, 8);
    expect(adapter.peakQueued, lessThanOrEqualTo(8));
    await stream.socket.close();
    await drain;
    expect(adapter.queued, 0);
    await stream.events.cancel();
  });

  test('duplicate-ACK flood reaches control rate limit', () async {
    final stream = await raw();
    stream.socket.add(input(stream.epoch));
    while (await stream.events.moveNext()) {
      if (stream.events.current is List<int>) break;
    }
    for (var i = 0; i < 200; ++i) {
      stream.socket.add(jsonEncode({'ack': 1}));
    }
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeReason, 'control_rate_limited');
    expect(adapter.stops, 1);
    await stream.events.cancel();
  });
}
