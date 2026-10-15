import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/native_remote_transform.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/remote_transform_client.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'transform_test_support.dart';

void main() {
  final address = Platform.environment['YINWEI_R1_RELAY_ORIGIN'];
  final path = Platform.environment['YINWEI_R2_NATIVE_DLL'];
  test('generated audio crosses public relay and actual laptop Rust DSP',
      () async {
    final password = remoteSecret();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    final controller = EngineController(engine: MockEngine());
    final adapter = NativeRemoteTransform.tryCreate(
        libraryPath: path,
        sourceAvailable: () => true,
        configuration: () => 'isolated fixture')!;
    final gateway = RemoteGateway(
        auth: RemoteAuth(RemoteAccount(
            username: 'r2-fixture',
            salt: base64UrlEncode(salt),
            hash: base64UrlEncode(await key.extractBytes()),
            iterations: 10)),
        transformAdapter: adapter,
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => false),
        loadAsset: (_) async =>
            Uint8List.fromList(utf8.encode('<html></html>')));
    final mode = DynamicLibrary.open(path!)
        .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'yinwei_set_mode');
    var received = 0, nativeMode = 0, spatialNonSilent = false;
    final client = RemoteTransformClient(
        origin: Uri.parse(address!),
        onOutput: (packet) {
          final data = ByteData.sublistView(packet);
          expect(data.getUint32(40, Endian.little), nativeMode);
          final first = data.getUint64(24, Endian.little);
          final dry = syntheticInput();
          for (var i = 0; i < 1024; ++i) {
            final sample = data.getFloat32(56 + i * 4, Endian.little);
            expect(sample.isFinite, true);
            if (nativeMode == 0) {
              expect(sample, dry[(first * 2 + i) % 960] / 32768);
            } else if (sample.abs() > 0.001) {
              spatialNonSilent = true;
            }
          }
          ++received;
        });
    try {
      await gateway.start(
          publicOrigin: Uri.parse(address),
          port: int.parse(Platform.environment['YINWEI_R1_RELAY_PORT']!));
      await client.signIn('r2-fixture', password);
      int? firstEpoch;
      for (nativeMode = 0; nativeMode <= 1; ++nativeMode) {
        expect(mode(nativeMode), 0);
        await client.start();
        if (firstEpoch != null) expect(client.epoch, isNot(firstEpoch));
        firstEpoch ??= client.epoch;
        final before = received;
        for (var i = 0; i < 35; ++i) {
          client.trySend(syntheticInput());
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(received - before, greaterThan(10));
        client.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(adapter.running, false);
      }
      expect(spatialNonSilent, true);
      expect(controller.hasOpenedFile, false);
      expect(controller.playing, false);
      await client.signOut();
      // ignore: avoid_print -- numeric, synthetic/native evidence only.
      print('R2_PUBLIC_NATIVE packets=$received originalExact=true '
          'spatialNonSilent=true freshEpoch=true localPlaybackUntouched=true');
    } finally {
      client.dispose();
      await gateway.close();
      controller.dispose();
    }
  },
      skip: address == null || path == null
          ? 'Manual isolated public/native test'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
