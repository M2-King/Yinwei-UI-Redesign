import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_deployment.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'fake_output_source.dart';

void main() {
  test(
      'public origin is canonical HTTPS and ports cannot reuse privileged services',
      () {
    final config = RemoteDeployment.fromEnvironment(
        {'YINWEI_REMOTE_PUBLIC_ORIGIN': 'https://yinwei.example.com/'});
    expect(config.origin.toString(), 'https://yinwei.example.com');
    expect(config.port, 0);
    final withEntry = RemoteDeployment.fromEnvironment(
        {'YINWEI_REMOTE_ENTRY_ORIGIN': 'https://yinwei-entry.example.com'});
    expect(
        withEntry.entryOrigin.toString(), 'https://yinwei-entry.example.com');
    expect(
        () => RemoteDeployment.fromEnvironment({
              'YINWEI_REMOTE_HOST_STATE_FILE':
                  File('${Directory.current.path}/assets/remote/host.json')
                      .absolute
                      .path
            }),
        throwsFormatException);
    for (final url in [
      'http://yinwei.example.com',
      'https://127.0.0.1',
      'https://localhost',
      'https://yinwei.example.com/app',
      'https://yinwei.example.com?url=x',
      'https://owner:secret@yinwei.example.com',
      'https://yinwei.example.com:8443'
    ]) {
      expect(
          () => RemoteDeployment.fromEnvironment(
              {'YINWEI_REMOTE_PUBLIC_ORIGIN': url}),
          throwsFormatException);
    }
    for (final port in ['443', '-1', '65536', 'not-a-number']) {
      expect(
          () => RemoteDeployment.fromEnvironment({'YINWEI_REMOTE_PORT': port}),
          throwsFormatException);
    }
    expect(
        () => RemoteDeployment.fromEnvironment(
            {'YINWEI_REMOTE_HOST_STATE_FILE': 'relative.json'}),
        throwsFormatException);
  });

  test(
      'HTTPS proxy uses secure cookies, exact Host/Origin, and private readiness',
      () async {
    final controller = EngineController(engine: MockEngine());
    final spatial = SpatialRuntimeAdapter()..bootstrap(controller.params);
    final auth = RemoteAuth(RemoteAccount(
        username: 'test-owner',
        salt: base64UrlEncode(List.filled(16, 0)),
        hash: base64UrlEncode(List.filled(32, 0))));
    final gateway = RemoteGateway(
        auth: auth,
        audioTap: FakeOutputSource(),
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: spatial,
            nativeBackend: true,
            liveRunning: () => false),
        loadAsset: (_) async => Uint8List.fromList(
            utf8.encode('<form id="signin">LOGIN_CSRF_TOKEN</form>')));
    await gateway.start(publicOrigin: Uri.parse('https://yinwei.example.com'));
    final client = HttpClient();
    Future<HttpClientResponse> get(String path,
        {String host = 'yinwei.example.com', String? token}) async {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:${gateway.port}$path'));
      request.followRedirects = false;
      request.headers.set('Host', host);
      if (token != null) request.headers.set('X-Yinwei-Host-Token', token);
      return request.close();
    }

    final directory = await Directory.systemTemp.createTemp('yinwei-remote-');
    final record = File('${directory.path}/host.json');
    final registration = RemoteHostRegistration(gateway, record);
    try {
      var response = await get('/remote/signin');
      expect(response.statusCode, 200);
      expect(response.cookies.single.secure, isTrue);
      expect(response.cookies.single.httpOnly, isTrue);
      expect(response.headers.value('Strict-Transport-Security'),
          'max-age=31536000');
      await response.drain<void>();
      response = await get('/remote/api/session');
      expect(response.statusCode, 401);
      await response.drain<void>();
      response =
          await get('/remote/signin', host: 'class-interpret.example.com');
      expect(response.statusCode, 403);
      await response.drain<void>();
      response = await get('/remote/internal/readiness');
      expect(response.statusCode, 401);
      await response.drain<void>();
      response =
          await get('/remote/internal/readiness', token: gateway.hostToken);
      final state = jsonDecode(await utf8.decodeStream(response));
      expect(state['nativeReady'], isTrue);
      expect(state['browserAudio'], isTrue);
      expect(state.containsKey('track'), isFalse);
      await registration.start();
      final first = jsonDecode(await record.readAsString());
      expect(first['projectId'], 'yinwei-remote');
      expect(first['port'], gateway.port);
      // Repeated registration also checks atomic replacement on Windows.
      await registration.start();
      expect(jsonDecode(await record.readAsString())['hostToken'],
          gateway.hostToken);
      await registration.close();
      expect(await record.exists(), isFalse);
      await record.writeAsString(jsonEncode({'projectId': 'bai'}));
      final foreign = RemoteHostRegistration(gateway, record);
      await expectLater(foreign.start(), throwsStateError);
      expect(jsonDecode(await record.readAsString())['projectId'], 'bai');
    } finally {
      await registration.close();
      client.close(force: true);
      await gateway.close();
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
}
