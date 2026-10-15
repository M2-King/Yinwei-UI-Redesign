import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'fake_output_source.dart';

void main() {
  test('opt-in synthetic browser UI preview', () async {
    final output = Platform.environment['YINWEI_REMOTE_UI_QA'];
    if (output == null) return;
    final directory = Directory(output);
    await directory.create(recursive: true);
    final stop = File('${directory.path}/stop-preview');
    if (await stop.exists()) await stop.delete();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: 'test-only-password', nonce: salt);
    final auth = RemoteAuth(RemoteAccount(
        username: 'test-owner',
        iterations: 10,
        salt: base64UrlEncode(salt),
        hash: base64UrlEncode(await key.extractBytes())));
    final livePreview = Platform.environment['YINWEI_REMOTE_UI_QA_LIVE'] == '1';
    var liveActive = livePreview;
    var liveSource = 'Synthetic Windows source A';
    final liveTap = FakeOutputSource();
    final controller = EngineController(engine: MockEngine());
    if (!livePreview) await controller.openPath('synthetic-preview.wav');
    final spatial = SpatialRuntimeAdapter()..bootstrap(controller.params);
    final coordinator = AppSessionCoordinator(
        controller: controller,
        spatial: spatial,
        sceneBridge: SpatialSceneBridge(adapter: spatial),
        nativeBackend: true,
        liveRunning: () => liveActive,
        liveAudioReady: () => liveActive,
        liveSnapshot: () => {
              'source': liveSource,
              'title': 'Synthetic Live Transfer',
              'captureHealthy': liveActive
            });
    if (!livePreview) {
      coordinator.registerLocalMedia(
          'synthetic-preview.wav', 'Synthetic UI test');
    }
    final gateway = RemoteGateway(
        auth: auth,
        coordinator: coordinator,
        audioTap: FakeOutputSource(),
        liveAudioTap: livePreview ? liveTap : null,
        loadAsset: (path) async {
          final bytes = await File(path).readAsBytes();
          if (path.endsWith('app.html')) {
            return Uint8List.fromList(utf8.encode(utf8
                .decode(bytes)
                .replaceFirst(
                    'Laptop audio → this browser’s speakers or headphones',
                    livePreview
                        ? 'SYNTHETIC LIVE TEST · No Windows capture or real DSP'
                        : 'SYNTHETIC UI TEST · No real audio engine')));
          }
          return bytes;
        });
    final publicOrigin = Platform.environment['YINWEI_REMOTE_QA_PUBLIC_ORIGIN'];
    if (publicOrigin != null &&
        !RegExp(r'^https://[a-z0-9-]+\.trycloudflare\.com$')
            .hasMatch(publicOrigin)) {
      throw const FormatException('Invalid disposable QA public origin');
    }
    await gateway.start(
        publicOrigin: publicOrigin == null ? null : Uri.parse(publicOrigin));
    await File('${directory.path}/ui-preview.json').writeAsString(
        jsonEncode({'origin': '${gateway.origin}', 'port': gateway.port}));
    final deadline = DateTime.now().add(const Duration(minutes: 8));
    try {
      while (!await stop.exists() && DateTime.now().isBefore(deadline)) {
        if (livePreview) {
          final state = File('${directory.path}/synthetic-live-state.json');
          if (await state.exists()) {
            final next = jsonDecode(await state.readAsString()) as Map;
            final nextActive = next['running'] == true;
            final nextSource = next['source'] == 'B'
                ? 'Synthetic Windows source B'
                : 'Synthetic Windows source A';
            if (nextSource != liveSource && liveTap.enabled) {
              liveTap.setEnabled(true);
            }
            liveActive = nextActive;
            liveSource = nextSource;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await gateway.close();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 9)));
}
