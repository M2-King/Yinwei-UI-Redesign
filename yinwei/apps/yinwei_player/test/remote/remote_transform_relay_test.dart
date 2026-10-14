import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/remote_transform_client.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

import 'transform_test_support.dart';

/// Opt-in test: the launcher supplies a separate short-lived QuickBridge and
/// quick tunnel. Uses generated samples and ephemeral test credentials only.
void main() {
  final address = Platform.environment['YINWEI_R1_RELAY_ORIGIN'];
  test('generated PCM roundtrips through exact public Yinwei message relay',
      () async {
    final origin = Uri.parse(address!);
    final password = remoteSecret();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    final auth = RemoteAuth(RemoteAccount(
        username: 'r1-fixture',
        salt: base64UrlEncode(salt),
        hash: base64UrlEncode(await key.extractBytes()),
        iterations: 10));
    final controller = EngineController(engine: MockEngine());
    final adapter = SyntheticTransformAdapter();
    final gateway = RemoteGateway(
        auth: auth,
        transformAdapter: adapter,
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => false),
        loadAsset: (_) async =>
            Uint8List.fromList(utf8.encode('<html></html>')));
    RemoteTransformClient? client;
    var received = 0;
    final latencies = <int>[];
    final sent = <int, DateTime>{};
    try {
      await gateway.start(
          publicOrigin: origin,
          port: int.parse(Platform.environment['YINWEI_R1_RELAY_PORT']!));
      client = RemoteTransformClient(
          origin: origin,
          onOutput: (packet) {
            final data = ByteData.sublistView(packet);
            final sequence = data.getUint64(16, Endian.little);
            final started = sent.remove(sequence)!;
            latencies.add(DateTime.now().difference(started).inMicroseconds);
            final pcm = syntheticInput();
            for (var i = 0; i < pcm.length; ++i) {
              expect(
                  data.getFloat32(56 + i * 4, Endian.little), pcm[i] / 32768);
            }
            ++received;
          });
      await client.signIn('r1-fixture', password);
      await client.start();
      final epoch = client.epoch;
      // Send well inside the test credit window; this checks fidelity and TLS/
      // WSS transport, not production throughput or device/audio latency.
      for (var i = 1; i <= 20; ++i) {
        sent[i] = DateTime.now();
        expect(client.trySend(syntheticInput()), true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      for (var i = 0; i < 100 && received < 20; ++i) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(received, 20);
      expect(client.dropped, 0);
      expect(client.serverDropped, 0);
      client.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(adapter.stops, 1);
      await client.start();
      expect(client.epoch, isNot(epoch));
      sent[1] = DateTime.now();
      expect(client.trySend(syntheticInput()), true);
      for (var i = 0; i < 100 && received < 21; ++i) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(received, 21);
      await client.signOut();
      expect(adapter.queued, 0);
      expect(controller.hasOpenedFile, false);
      expect(controller.playing, false);
      latencies.sort();
      // Numeric transport-only evidence. Never log passwords, cookies or tickets.
      // ignore: avoid_print -- numeric manual-test evidence only.
      print('R1_PUBLIC_TRANSPORT packets=$received drops=0 '
          'medianMs=${latencies[latencies.length ~/ 2] / 1000} '
          'p95Ms=${latencies[(latencies.length * .95).ceil() - 1] / 1000} '
          'freshEpoch=true localPlaybackUntouched=true');
    } finally {
      client?.dispose();
      await gateway.close();
      controller.dispose();
    }
  },
      skip: address == null ? 'Manual generated-PCM public relay test' : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
