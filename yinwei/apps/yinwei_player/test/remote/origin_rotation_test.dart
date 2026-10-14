import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_deployment.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'fake_output_source.dart';

const oldOrigin = 'https://yinwei-old.trycloudflare.com';
const newOrigin = 'https://yinwei-new.trycloudflare.com';

class DelayedAuth extends RemoteAuth {
  DelayedAuth(super.account);
  static Completer<void>? entered, proceed;
  @override
  Future<({String token, RemoteSession session})> signin(
      String username, String password) async {
    entered?.complete();
    if (proceed != null) await proceed!.future;
    return super.signin(username, password);
  }
}

void main() {
  late RemoteGateway gateway;
  late DelayedAuth auth;
  late EngineController controller;
  late HttpClient client;
  late AppSessionCoordinator coordinator;
  late FakeOutputSource tap;
  setUp(() async {
    DelayedAuth.entered = null;
    DelayedAuth.proceed = null;
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(
            password: 'synthetic-rotation-test', nonce: salt);
    auth = DelayedAuth(RemoteAccount(
        username: 'test-owner',
        salt: base64UrlEncode(salt),
        hash: base64UrlEncode(await key.extractBytes()),
        iterations: 10));
    controller = EngineController(engine: MockEngine());
    final spatial = SpatialRuntimeAdapter()..bootstrap(controller.params);
    coordinator = AppSessionCoordinator(
        controller: controller,
        spatial: spatial,
        nativeBackend: true,
        liveRunning: () => false);
    tap = FakeOutputSource();
    gateway = RemoteGateway(
        auth: auth,
        coordinator: coordinator,
        audioTap: tap,
        allowOriginRotation: true,
        loadAsset: (_) async => Uint8List.fromList(
            utf8.encode('<form id="signin">LOGIN_CSRF_TOKEN</form>')));
    await gateway.start(publicOrigin: Uri.parse(oldOrigin));
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await gateway.close();
    controller.dispose();
  });
  Future<({int status, String text, List<Cookie> cookies})> request(String path,
      {String origin = oldOrigin,
      Map<String, dynamic>? body,
      String? token,
      String? cookie,
      String? csrf}) async {
    final req = await client.openUrl(body == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:${gateway.port}$path'));
    req.headers.set('Host', Uri.parse(origin).host);
    if (token != null) req.headers.set('X-Yinwei-Host-Token', token);
    if (cookie != null) req.headers.set('Cookie', cookie);
    if (csrf != null) req.headers.set('X-CSRF-Token', csrf);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.headers.set('Origin', origin);
      req.write(jsonEncode(body));
    }
    final response = await req.close();
    return (
      status: response.statusCode,
      text: await utf8.decodeStream(response),
      cookies: response.cookies
    );
  }

  Map<String, dynamic> rotation(String value) =>
      {'origin': value, 'hostSessionId': coordinator.hostSessionId};
  test(
      'only private owner token and exact temporary origins can rotate gateway',
      () async {
    expect(
        (await request('/remote/internal/origin', body: rotation(newOrigin)))
            .status,
        401);
    expect(
        (await request('/remote/internal/origin',
                token: gateway.hostToken,
                body: {...rotation(newOrigin), 'hostSessionId': 'other-host'}))
            .status,
        400);
    for (final invalid in [
      'http://yinwei-new.trycloudflare.com',
      'https://class.example.com',
      '$newOrigin:443',
      '$newOrigin/remote',
      '$newOrigin?target=x',
      'https://owner:secret@yinwei-new.trycloudflare.com'
    ]) {
      expect(
          (await request('/remote/internal/origin',
                  token: gateway.hostToken, body: rotation(invalid)))
              .status,
          400,
          reason: invalid);
    }
    expect(gateway.origin.toString(), oldOrigin);
  });
  test(
      'rotation closes browser audio and control sessions while preserving playback and spatial state',
      () async {
    await controller.openPath('synthetic-local.wav');
    await controller.play();
    final track = controller.track,
        azimuth = controller.params.azimuthDeg,
        hostSession = coordinator.hostSessionId;
    final login = await auth.signin('test-owner', 'synthetic-rotation-test');
    coordinator.acquireControl(login.session.deviceId);
    final ticket = auth.ticket(login.session, 'audio');
    final socket = await WebSocket.connect(
        'ws://127.0.0.1:${gateway.port}/remote/ws/audio',
        headers: {
          'Host': Uri.parse(oldOrigin).host,
          'Origin': oldOrigin,
          'Cookie': '__Host-yinwei=${login.token}'
        });
    final events = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'ticket': ticket}));
    expect(await events.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(jsonDecode(events.current as String)['type'], 'audioReady');
    expect(tap.enabled, isTrue);
    expect(
        (await request('/remote/internal/origin',
                token: gateway.hostToken, body: rotation(newOrigin)))
            .status,
        200);
    expect(tap.enabled, isFalse);
    expect(auth.sessions, isEmpty);
    expect(controller.playing, isTrue);
    expect(controller.track, same(track));
    expect(controller.params.azimuthDeg, azimuth);
    expect(coordinator.hostSessionId, hostSession);
    expect((await request('/remote/signin')).status, 403);
    expect(
        (await request('/remote/api/session',
                origin: newOrigin, cookie: '__Host-yinwei=${login.token}'))
            .status,
        401);
    expect((await request('/remote/signin', origin: newOrigin)).status, 200);
    await events.cancel();
    await socket.close();
    final dir =
        await Directory.systemTemp.createTemp('yinwei-rotation-record-');
    final file = File('${dir.path}/host.json'),
        registration =
            RemoteHostRegistration(gateway, File('${dir.path}/host.json'));
    try {
      await registration.start();
      expect(jsonDecode(await file.readAsString())['publicOrigin'], newOrigin);
    } finally {
      await registration.close();
      await dir.delete(recursive: true);
    }
  });
  test('a login pending during rotation cannot create a surviving session',
      () async {
    final form = await request('/remote/signin');
    final nonce = form.cookies.single.value;
    DelayedAuth.entered = Completer<void>();
    DelayedAuth.proceed = Completer<void>();
    final pending = request('/remote/api/auth/signin',
        body: {'username': 'test-owner', 'password': 'synthetic-rotation-test'},
        cookie: '__Host-yinwei_prelogin=$nonce',
        csrf: nonce);
    await DelayedAuth.entered!.future;
    expect(
        (await request('/remote/internal/origin',
                token: gateway.hostToken, body: rotation(newOrigin)))
            .status,
        200);
    DelayedAuth.proceed!.complete();
    expect((await pending).status, 409);
    expect(auth.sessions, isEmpty);
  });
}
