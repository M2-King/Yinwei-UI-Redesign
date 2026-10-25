import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/listen_stream_source.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'fake_output_source.dart';

class _FakeOpus implements ListenOpusEncoder {
  @override
  bool setBitrate(int bitrate) => true;
  @override
  Uint8List? encode(Float32List pcm) => Uint8List.fromList([0xfc, 1, 2, 3]);
  @override
  void reset() {}
  @override
  void close() {}
}

void main() {
  late RemoteGateway gateway;
  late RemoteAuth auth;
  late EngineController controller;
  late FakeOutputSource audioTap;
  late FakeOutputSource liveTap;
  late bool liveActive;
  late bool liveReady;
  late HttpClient client;
  late Map<String, String> cookies;
  late String loginCsrf;
  late String csrf;
  var sodaReads = 0;
  const password = 'test-only-password';

  setUp(() async {
    // Low-cost fixture only. Production file loading rejects this iteration
    // count; the production-cost provisioning test below exercises that gate.
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    auth = RemoteAuth(RemoteAccount(
        username: 'test-owner',
        salt: base64UrlEncode(salt),
        hash: base64UrlEncode(await key.extractBytes()),
        iterations: 10));
    sodaReads = 0;
    controller = EngineController(engine: MockEngine());
    final spatial = SpatialRuntimeAdapter()..bootstrap(controller.params);
    audioTap = FakeOutputSource();
    liveTap = FakeOutputSource();
    liveActive = false;
    liveReady = true;
    gateway = RemoteGateway(
        auth: auth,
        audioTap: audioTap,
        liveAudioTap: liveTap,
        allowArrayFileAudio: false,
        createOpusEncoder: _FakeOpus.new,
        // Never from this machine's settings (the owner's laptop has UDP on).
        listenUdp: false,
        coordinator: AppSessionCoordinator(
            libraryList: (request) async {
              sodaReads++;
              return {
                'available': true,
                'lists': [],
                'rows': [],
                'echo': request['list']
              };
            },
            controller: controller,
            spatial: spatial,
            nativeBackend: true,
            liveRunning: () => liveActive,
            liveAudioReady: () => liveReady,
            liveSnapshot: () => {
                  'source': 'Synthetic Windows source',
                  'title': 'Live test',
                  'captureHealthy': true,
                  'openApp': '汽水音乐',
                  'azimuthDeg': 42.5,
                  'startStage': 'pressing'
                }),
        loadAsset: (_) async => Uint8List.fromList(
            utf8.encode('<meta content="LOGIN_CSRF_TOKEN">')));
    await gateway.start();
    client = HttpClient();
    cookies = {};
  });
  tearDown(() async {
    client.close(force: true);
    await gateway.close();
    controller.dispose();
  });

  Future<({int status, String text, HttpHeaders headers})> request(String path,
      {Map<String, dynamic>? body, String? origin, String? csrfToken}) async {
    final req = await client.openUrl(
        body == null ? 'GET' : 'POST', gateway.origin.resolve(path));
    req.followRedirects = false;
    req.headers.set(
        'Cookie', cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.headers.set('Origin', origin ?? gateway.origin.toString());
      if (csrfToken != null) req.headers.set('X-CSRF-Token', csrfToken);
      req.write(jsonEncode(body));
    }
    final response = await req.close();
    for (final cookie in response.cookies) {
      if (cookie.maxAge == 0) {
        cookies.remove(cookie.name);
      } else {
        cookies[cookie.name] = cookie.value;
      }
    }
    return (
      status: response.statusCode,
      text: await utf8.decodeStream(response),
      headers: response.headers
    );
  }

  Future<void> signin() async {
    await request('/remote/signin');
    loginCsrf = cookies['yinwei_prelogin']!;
    final response = await request('/remote/api/auth/signin',
        body: {'username': 'test-owner', 'password': password},
        csrfToken: loginCsrf);
    expect(response.status, 200);
    csrf = (jsonDecode((await request('/remote/api/session')).text)
        as Map)['csrf'] as String;
  }

  test('Soda browse requires owner session and CSRF but no control lease',
      () async {
    final unauthorized = await request('/remote/api/commands', body: {});
    expect(unauthorized.status, 401);
    expect(sodaReads, 0);
    await signin();
    final noCsrf = await request('/remote/api/commands', body: {});
    expect(noCsrf.status, 403);
    expect(sodaReads, 0);
    final response = await request('/remote/api/commands',
        body: {
          'protocolVersion': 1,
          'hostSessionId': gateway.coordinator.hostSessionId,
          'commandId': 'library_read_001',
          'type': 'library.list',
          'payload': {'list': 'host_list'}
        },
        csrfToken: csrf);
    expect(response.status, 200);
    expect((jsonDecode(response.text) as Map)['library']['echo'], 'host_list');
    expect(sodaReads, 1);
  });

  test('Soda browse does not expose a GET or query-string variant', () async {
    await signin();
    expect((await request('/remote/api/soda/library')).status, 404);
    expect(sodaReads, 0);
  });

  Future<({WebSocket socket, StreamIterator<dynamic> events})>
      subscribeAudio() async {
    final ticket = (jsonDecode((await request('/remote/api/ws-ticket',
            body: {'purpose': 'audio'}, csrfToken: csrf))
        .text) as Map)['ticket'];
    final socket = await WebSocket.connect(
        gateway.origin
            .replace(scheme: 'ws', path: '/remote/ws/audio')
            .toString(),
        headers: {
          'Origin': gateway.origin.toString(),
          'Cookie': 'yinwei_local=${cookies['yinwei_local']}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect((jsonDecode(events.current as String) as Map)['type'], 'audioReady');
    return (socket: socket, events: events);
  }

  test('array file audio stays blocked by default; existing stream closes',
      () async {
    await signin();
    final stream = await subscribeAudio();
    await controller.applyArrayMode(ArrayMode.stereo2);
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeReason, 'audio_source_changed');
    expect(
        (await request('/remote/api/ws-ticket',
                body: {'purpose': 'audio'}, csrfToken: csrf))
            .status,
        400);
    liveActive = true;
    final live = await subscribeAudio();
    expect(liveTap.enabled, true);
    await live.events.cancel();
    await live.socket.close();
  });

  test(
      'explicit file-array opt-in streams file tap but still gates Live readiness',
      () async {
    await gateway.close();
    auth = RemoteAuth(auth.account);
    audioTap = FakeOutputSource();
    liveTap = FakeOutputSource();
    gateway = RemoteGateway(
        auth: auth,
        audioTap: audioTap,
        liveAudioTap: liveTap,
        allowArrayFileAudio: true,
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => liveActive,
            liveAudioReady: () => liveReady),
        loadAsset: (_) async => Uint8List.fromList(
            utf8.encode('<meta content="LOGIN_CSRF_TOKEN">')));
    await gateway.start();
    await signin();
    await controller.applyArrayMode(ArrayMode.stereo2);
    final stream = await subscribeAudio();
    expect(audioTap.enabled, true);
    expect(liveTap.enabled, false);
    await stream.events.cancel();
    await stream.socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    liveActive = true;
    liveReady = false;
    expect(
        (await request('/remote/api/ws-ticket',
                body: {'purpose': 'audio'}, csrfToken: csrf))
            .status,
        400);
  });

  test(
      'live listener streams without an imported file and file commands stay blocked',
      () async {
    liveActive = true;
    await signin();
    final snapshot = (jsonDecode((await request('/remote/api/session')).text)
        as Map)['snapshot'] as Map;
    expect(snapshot['audioSource'], 'live');
    expect((snapshot['capabilities'] as Map)['browserLiveAudio'], true);
    expect(controller.hasOpenedFile, false);
    expect((snapshot['live'] as Map)['remoteControls'], false);
    expect((snapshot['live'] as Map)['openApp'], '汽水音乐',
        reason: 'the app a remote start opens, named by the laptop');
    expect((snapshot['live'] as Map)['azimuthDeg'], 42.5,
        reason: 'where the sound is now, for the orbit');
    expect((snapshot['live'] as Map)['startStage'], 'pressing');
    expect(
        (await request('/remote/api/control/lease', body: {}, csrfToken: csrf))
            .status,
        409);
    final stream = await subscribeAudio();
    expect(await stream.events.moveNext().timeout(const Duration(seconds: 3)),
        true);
    final packet = ByteData.sublistView(
        Uint8List.fromList(stream.events.current as List<int>));
    expect(packet.getUint32(0, Endian.little), 0x31574e59);
    expect(liveTap.enabled, true);
    expect(audioTap.enabled, false);
    await stream.events.cancel();
    await stream.socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(liveTap.enabled, false);
    expect(liveActive, true);
  });

  test('starting live does not fall back to a file tap', () async {
    liveActive = true;
    liveReady = false;
    await signin();
    expect(
        (await request('/remote/api/ws-ticket',
                body: {'purpose': 'audio'}, csrfToken: csrf))
            .status,
        400);
    expect(audioTap.enabled, false);
    expect(liveTap.enabled, false);
  });

  test('local live stop closes only browser audio and allows a fresh start',
      () async {
    liveActive = true;
    await signin();
    final stream = await subscribeAudio();
    liveActive = false;
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeReason, 'live_stopped');
    expect(liveTap.enabled, false);
    expect((await request('/remote/api/session')).status, 200);
    liveActive = true;
    final restarted = await subscribeAudio();
    expect(
        await restarted.events.moveNext().timeout(const Duration(seconds: 3)),
        true);
    expect(liveTap.enabled, true);
    expect(audioTap.enabled, false);
    await restarted.events.cancel();
    await restarted.socket.close();
  });

  test('file to live route change cannot reuse the file audio subscription',
      () async {
    await signin();
    final stream = await subscribeAudio();
    liveActive = true;
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeReason, 'audio_source_changed');
    expect(audioTap.enabled, false);
    expect(liveTap.enabled, false);
    final live = await subscribeAudio();
    expect(liveTap.enabled, true);
    await live.events.cancel();
    await live.socket.close();
  });

  test(
      'live source retarget flushes epochs without disconnecting controls or restarting capture',
      () async {
    liveActive = true;
    await signin();
    final stream = await subscribeAudio();
    expect(await stream.events.moveNext().timeout(const Duration(seconds: 3)),
        true);
    final before = ByteData.sublistView(
            Uint8List.fromList(stream.events.current as List<int>))
        .getUint64(8, Endian.little);
    // Synthetic producer models the native source/hold boundary. The gateway
    // must keep the subscription and transmit only monotonic newer epochs.
    liveTap.setEnabled(true);
    var newer = false;
    for (var i = 0; i < 12; i++) {
      expect(await stream.events.moveNext().timeout(const Duration(seconds: 3)),
          true);
      final packet = ByteData.sublistView(
          Uint8List.fromList(stream.events.current as List<int>));
      stream.socket
          .add(jsonEncode({'ack': packet.getUint64(16, Endian.little)}));
      if (packet.getUint64(8, Endian.little) > before) {
        newer = true;
        break;
      }
    }
    expect(newer, true);
    expect(liveActive, true);
    expect((await request('/remote/api/session')).status, 200);
    await stream.events.cancel();
    await stream.socket.close();
  });

  test('browser policy explicitly permits only the exact own WebSocket origin',
      () async {
    final response = await request('/remote/signin');
    final policy = response.headers.value('Content-Security-Policy')!;
    expect(policy,
        contains("connect-src 'self' ${gateway.origin.replace(scheme: 'ws')}"));
    expect(policy, isNot(contains("connect-src *")));
    expect(policy, isNot(contains("wss:;")));
    expect(response.headers.value('Permissions-Policy'),
        contains('display-capture=(self)'));
  });

  test('capture probe is authenticated and stores only strict numeric reports',
      () async {
    expect((await request('/remote/capture-probe')).status, 303);
    expect((await request('/remote/capture-probe.js')).status, 401);
    await signin();
    expect((await request('/remote/capture-probe')).status, 200);
    expect((await request('/remote/capture-meter-worklet.js')).status, 200);
    final valid = {
      'version': 1,
      'stage': 'active',
      'supported': true,
      'secureContext': true,
      'standalone': true,
      'visibility': 'visible',
      'audioTrack': true,
      'videoTrack': true,
      'audioState': 'live',
      'sampleRate': 48000,
      'channelCount': 2,
      'callbacks': 42,
      'frames': 5376,
      'rmsDb': -21.5,
      'peakDb': -6.25,
      'silentCallbacks': 0,
      'discontinuities': 1,
      'maxGapMs': 54.0,
      'tone997Db': -70.0,
      'tone1499Db': -72.0,
      'recaptureHint': 'clear',
      'dryRouting': 'source_only',
      'errorCode': 'none'
    };
    expect(
        (await request('/remote/api/capture-probe',
                body: valid, csrfToken: csrf))
            .status,
        200);
    final reports =
        jsonDecode((await request('/remote/api/capture-probe')).text) as Map;
    final saved = (reports['reports'] as List).single as Map;
    expect(saved['rmsDb'], -21.5);
    expect(saved['observedAt'], isA<String>());
    expect(saved.keys, isNot(contains('audio')));

    for (final invalid in [
      {
        ...valid,
        'rawSamples': [0.1, 0.2]
      },
      {...valid, 'rmsDb': 'raw media'},
      {...valid, 'recaptureHint': 'definitely-safe'},
      {...valid, 'sampleRate': 999999}
    ]) {
      expect(
          (await request('/remote/api/capture-probe',
                  body: invalid, csrfToken: csrf))
              .status,
          400);
    }
  });

  test('anonymous API, application assets, scene and audio are denied',
      () async {
    for (final path in [
      '/remote/api/session',
      '/remote/app.js',
      '/remote/capture-probe.js',
      '/remote/capture-meter-worklet.js',
      '/remote/scene.js',
      '/remote/ws/events',
      '/remote/ws/audio',
      '/remote/ws/transform'
    ]) {
      expect((await request(path)).status, 401, reason: path);
    }
    expect((await request('/remote/app')).status, 303);
    final health = await request('/remote/health');
    expect(health.status, 200);
    expect(health.text, isNot(contains('track')));
  });

  test('login requires the exact origin and prelogin CSRF token', () async {
    await request('/remote/signin');
    final body = {'username': 'test-owner', 'password': password};
    expect((await request('/remote/api/auth/signin', body: body)).status, 403);
    expect(
        (await request('/remote/api/auth/signin',
                body: body,
                csrfToken: cookies['yinwei_prelogin'],
                origin: 'https://attacker.example'))
            .status,
        403);
  });

  test('authenticated controls require CSRF and signout revokes the session',
      () async {
    await signin();
    expect((await request('/remote/api/control/lease', body: {})).status, 403);
    expect(
        (await request('/remote/api/control/lease', body: {}, csrfToken: csrf))
            .status,
        200);
    expect(
        (await request('/remote/api/auth/signout', body: {}, csrfToken: csrf))
            .status,
        200);
    expect((await request('/remote/api/session')).status, 401);
  });

  test('bad credentials do not create a session', () async {
    await request('/remote/signin');
    expect(
        (await request('/remote/api/auth/signin',
                body: {'username': 'test-owner', 'password': 'wrong'},
                csrfToken: cookies['yinwei_prelogin']))
            .status,
        401);
    expect((await request('/remote/api/session')).status, 401);
  });

  test('tickets are one-use and bound to the signed-in device and purpose',
      () async {
    await signin();
    final session = auth.authenticate(cookies['yinwei_local'])!;
    final ticket = auth.ticket(session, 'events');
    expect(auth.consumeTicket(session, ticket, 'events'), isTrue);
    expect(auth.consumeTicket(session, ticket, 'events'), isFalse);
  });

  test('normal gateway has no remote transform adapter or media uplink',
      () async {
    await signin();
    final session =
        jsonDecode((await request('/remote/api/session')).text) as Map;
    expect(session['remoteTransformAvailable'], false);
    expect(
        (await request('/remote/api/ws-ticket',
                body: {'purpose': 'transform'}, csrfToken: csrf))
            .status,
        400);
    expect((await request('/remote/ws/transform')).status, 409);
    expect(audioTap.enabled, false);
    expect(liveTap.enabled, false);
  });

  test(
      'authenticated event WebSocket sends actual state and closes on revocation',
      () async {
    await signin();
    final response = await request('/remote/api/ws-ticket',
        body: {'purpose': 'events'}, csrfToken: csrf);
    final ticket = (jsonDecode(response.text) as Map)['ticket'];
    final socket = await WebSocket.connect(
        gateway.origin
            .replace(scheme: 'ws', path: '/remote/ws/events')
            .toString(),
        headers: {
          'Origin': gateway.origin.toString(),
          'Cookie': 'yinwei_local=${cookies['yinwei_local']}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final snapshot = jsonDecode(events.current as String) as Map;
    expect(snapshot['type'], 'snapshot');
    expect((snapshot['snapshot'] as Map)['sceneRevision'], 1);
    socket.add(jsonEncode({'ack': snapshot['sequence']}));
    await request('/remote/api/auth/signout', body: {}, csrfToken: csrf);
    // StreamIterator pauses after each event. Drain until close so the close
    // handshake is consumed rather than waiting on a paused stream's sink.
    while (await events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(socket.closeCode, 1008);
    await events.cancel();
  });

  test('unknown media IDs and raw filesystem input never open a file',
      () async {
    await signin();
    final state = (jsonDecode((await request('/remote/api/session')).text)
        as Map)['snapshot'] as Map;
    final lease = jsonDecode(
        (await request('/remote/api/control/lease', body: {}, csrfToken: csrf))
            .text) as Map;
    final response =
        await request('/remote/api/commands', csrfToken: csrf, body: {
      'protocolVersion': 1,
      'commandId': 'unknown_media_001',
      'hostSessionId': state['hostSessionId'],
      'controlLeaseId': lease['controlLeaseId'],
      'expectedStateVersion': state['stateVersion'],
      'expectedSceneRevision': state['sceneRevision'],
      'type': 'open',
      'payload': {'mediaId': r'C:\private\secret.wav'}
    });
    expect(response.status, 404);
    expect(controller.hasOpenedFile, isFalse);
  });

  test('owner config rejects weak hashes and unsupported role', () {
    expect(() => RemoteAccount.fromJson(auth.account.toJson()),
        throwsFormatException);
    expect(
        () =>
            RemoteAccount.fromJson({...auth.account.toJson(), 'role': 'admin'}),
        throwsFormatException);
  });

  test('real-cost owner provisioning persists only a valid salted hash',
      () async {
    final account =
        await RemoteAccount.create('owner', 'long-private-test-password');
    expect(account.iterations, remotePasswordIterations);
    expect(account.toJson().containsKey('password'), isFalse);
    expect(RemoteAccount.fromJson(account.toJson()).username, 'owner');
  });

  test('audio subscription mirrors PCM and closing leaves laptop playing',
      () async {
    await controller.openPath('synthetic.wav');
    await controller.play();
    await signin();
    final ticket = (jsonDecode((await request('/remote/api/ws-ticket',
            body: {'purpose': 'audio'}, csrfToken: csrf))
        .text) as Map)['ticket'];
    final socket = await WebSocket.connect(
        gateway.origin
            .replace(scheme: 'ws', path: '/remote/ws/audio')
            .toString(),
        headers: {
          'Origin': gateway.origin.toString(),
          'Cookie': 'yinwei_local=${cookies['yinwei_local']}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect((jsonDecode(events.current as String) as Map)['type'], 'audioReady');
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final packet =
        ByteData.sublistView(Uint8List.fromList(events.current as List<int>));
    expect(packet.getUint32(0, Endian.little), 0x31574e59);
    expect(packet.getUint32(36, Endian.little), 512);
    final sequence = packet.getUint64(16, Endian.little);
    socket.add(jsonEncode({'ack': sequence}));
    socket.add(jsonEncode({'ack': sequence}));
    final busy = await request('/remote/api/ws-ticket',
        body: {'purpose': 'audio'}, csrfToken: csrf);
    expect(busy.status, 409);
    expect((jsonDecode(busy.text) as Map)['error'], 'audio_busy');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(audioTap.enabled, isTrue);
    final closing = socket.close();
    while (await events.moveNext().timeout(const Duration(seconds: 3))) {}
    await closing;
    await events.cancel();
    expect(audioTap.enabled, isFalse);
    expect(controller.playing, isTrue);
  });

  test('the app chooses Opus or lossless; browsers keep plain PCM', () async {
    await controller.openPath('synthetic.wav');
    await controller.play();
    await signin();
    final ticket = (jsonDecode((await request('/remote/api/ws-ticket',
            body: {'purpose': 'audio'}, csrfToken: csrf))
        .text) as Map)['ticket'];
    final socket = await WebSocket.connect(
        gateway.origin
            .replace(scheme: 'ws', path: '/remote/ws/audio')
            .toString(),
        headers: {
          'Origin': gateway.origin.toString(),
          'Cookie': 'yinwei_local=${cookies['yinwei_local']}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket, 'quality': 'high'}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final ready = jsonDecode(events.current as String) as Map;
    expect(ready['type'], 'audioReady');
    expect(ready['codecs'], ['pcm', 'opus']);
    expect(ready['quality'], 'high');
    Future<ByteData> next() async {
      expect(
          await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
      final p =
          ByteData.sublistView(Uint8List.fromList(events.current as List<int>));
      socket.add(jsonEncode({'ack': p.getUint64(16, Endian.little)}));
      return p;
    }

    final opus = await next();
    expect(opus.getUint32(0, Endian.little), 0x314f4e59); // YNO1
    expect(opus.getUint32(36, Endian.little), 960);
    expect(opus.lengthInBytes, 60);
    expect(opus.getUint64(16, Endian.little), 1);
    socket.add(jsonEncode({'quality': 'lossless'}));
    ByteData pcm;
    do {
      pcm = await next();
    } while (pcm.getUint32(0, Endian.little) != 0x31574e59);
    expect(pcm.getUint32(36, Endian.little), 512);
    socket.add(jsonEncode({'quality': 'ultra'}));
    while (await events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(socket.closeCode, 1008);
    expect(socket.closeReason, 'invalid_audio_quality');
    await events.cancel();
    expect(controller.playing, isTrue);
  });

  Future<Map> audioReadyWith(Map<String, Object> hello) async {
    await controller.openPath('synthetic.wav');
    await controller.play();
    final ticket = (jsonDecode((await request('/remote/api/ws-ticket',
            body: {'purpose': 'audio'}, csrfToken: csrf))
        .text) as Map)['ticket'];
    final socket = await WebSocket.connect(
        gateway.origin
            .replace(scheme: 'ws', path: '/remote/ws/audio')
            .toString(),
        headers: {
          'Origin': gateway.origin.toString(),
          'Cookie': 'yinwei_local=${cookies['yinwei_local']}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket, ...hello}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final ready = jsonDecode(events.current as String) as Map;
    await socket.close();
    await events.cancel();
    return ready;
  }

  test('Listen over UDP off (default): audioReady is unchanged', () async {
    await signin();
    final ready = await audioReadyWith(
        {'quality': 'high', 'transports': ['udp', 'wss']});
    expect(ready['type'], 'audioReady');
    expect(ready.containsKey('conceal'), isFalse);
    expect(ready.containsKey('udp'), isFalse);
  });

  test('Listen over UDP on: never offered on the public route', () async {
    await gateway.close();
    auth = RemoteAuth(auth.account);
    audioTap = FakeOutputSource();
    gateway = RemoteGateway(
        auth: auth,
        audioTap: audioTap,
        createOpusEncoder: _FakeOpus.new,
        listenUdp: true,
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => false,
            liveAudioReady: () => false),
        loadAsset: (_) async => Uint8List.fromList(
            utf8.encode('<meta content="LOGIN_CSRF_TOKEN">')));
    await gateway.start();
    await signin();
    final ready = await audioReadyWith(
        {'quality': 'high', 'transports': ['udp', 'wss']});
    expect(ready['conceal'], isTrue, reason: 'smooth gaps on the WebSocket too');
    expect(ready.containsKey('udp'), isFalse,
        reason: 'UDP only inside the private Tailscale route');
  });

  test('stalled audio subscriber loses bounded credit without pausing laptop',
      () async {
    await controller.openPath('synthetic.wav');
    await controller.play();
    await signin();
    final stream = await subscribeAudio();
    var chunks = 0;
    while (await stream.events.moveNext().timeout(const Duration(seconds: 7))) {
      if (stream.events.current is List<int>) chunks++;
    }
    expect(chunks, RemoteGateway.audioCredit);
    expect(stream.socket.closeCode, 1008);
    expect(audioTap.enabled, isFalse);
    expect(controller.playing, isTrue);
    await stream.events.cancel();
  });

  test('signout revokes an active audio stream without pausing laptop',
      () async {
    await controller.openPath('synthetic.wav');
    await controller.play();
    await signin();
    final stream = await subscribeAudio();
    await request('/remote/api/auth/signout', body: {}, csrfToken: csrf);
    while (
        await stream.events.moveNext().timeout(const Duration(seconds: 3))) {}
    expect(stream.socket.closeCode, 1008);
    expect(audioTap.enabled, isFalse);
    expect(controller.playing, isTrue);
    await stream.events.cancel();
  });

  test('disabled owner invalidates previously authenticated sessions',
      () async {
    await signin();
    auth.account.enabled = false;
    expect((await request('/remote/api/session')).status, 401);
  });
}
