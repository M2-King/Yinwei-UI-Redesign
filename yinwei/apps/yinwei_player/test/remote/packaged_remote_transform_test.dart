import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/remote_transform_client.dart';
import 'transform_test_support.dart';

void main() {
  final executable = Platform.environment['YINWEI_R2_PLAYER_EXE'];
  test(
      'staged Windows player authenticates and returns native DSP across restart',
      () async {
    final temporary = await Directory.systemTemp.createTemp('yinwei-r2-smoke-');
    Process? process;
    RemoteTransformClient? client;
    var consoleErrors = 0;
    final logs = <Future<void>>[];
    Future<void> inspect(Stream<List<int>> stream) async {
      var tail = '';
      await for (final bytes in stream) {
        final text = tail + utf8.decode(bytes, allowMalformed: true);
        if (RegExp(r'Unhandled Exception|EXCEPTION CAUGHT|\[ERROR:flutter/')
            .hasMatch(text)) {
          ++consoleErrors;
        }
        tail = text.length > 256 ? text.substring(text.length - 256) : text;
      }
    }

    try {
      final password = remoteSecret();
      final account = await RemoteAccount.create('r2-fixture', password);
      final owner = File('${temporary.path}/fixture-owner.json');
      final registration = File('${temporary.path}/fixture-host.json');
      await owner.writeAsString(jsonEncode({
        'projectId': 'yinwei-remote',
        'version': 1,
        'owner': account.toJson()
      }));
      final env = Map<String, String>.from(Platform.environment)
        ..removeWhere(
            (key, _) => key.startsWith('YINWEI_') || key == 'FLUTTER_TEST')
        ..addAll({
          'YINWEI_REMOTE_ENABLED': '1',
          'YINWEI_REMOTE_ACCOUNT_FILE': owner.path,
          'YINWEI_REMOTE_HOST_STATE_FILE': registration.path,
          'YINWEI_REMOTE_PORT': '0',
          'YINWEI_START_FULL': '1'
        });
      process = await Process.start(executable!, const [],
          workingDirectory: File(executable).parent.path,
          environment: env,
          includeParentEnvironment: false);
      // Do not echo the player's diagnostic stream or private registration.
      logs.add(inspect(process.stdout));
      logs.add(inspect(process.stderr));
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (
          !await registration.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await registration.exists(), true,
          reason: 'Packaged native player did not register its gateway');
      final state = jsonDecode(await registration.readAsString()) as Map;
      final origin = Uri.parse('http://127.0.0.1:${state['port']}');
      var outputs = 0, nonSilent = false;
      client = RemoteTransformClient(
          origin: origin,
          allowLoopbackForTests: true,
          onOutput: (packet) {
            final data = ByteData.sublistView(packet);
            for (var i = 56; i < packet.length; i += 4) {
              final value = data.getFloat32(i, Endian.little);
              expect(value.isFinite, true);
              nonSilent |= value.abs() > 0.001;
            }
            ++outputs;
          });
      await client.signIn('r2-fixture', password);
      int? previousEpoch;
      for (var attempt = 0; attempt < 2; ++attempt) {
        await client.start();
        if (previousEpoch != null) expect(client.epoch, isNot(previousEpoch));
        previousEpoch = client.epoch;
        final before = outputs;
        for (var i = 0; i < 250 && outputs - before < 12; ++i) {
          client.trySend(syntheticInput());
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(outputs - before, greaterThanOrEqualTo(12));
        client.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(nonSilent, true);
      await client.signOut();
      // ignore: avoid_print -- bounded synthetic verification metadata only.
      print('R2_PACKAGED_PLAYER authenticated=true packets=$outputs '
          'nativeDSP=true nonSilent=true freshEpoch=true');
    } finally {
      client?.dispose();
      process?.kill(); // Only the fixture-owned player created above.
      if (process != null) await process.exitCode;
      await Future.wait(logs);
      final root = Directory.systemTemp.absolute.path.toLowerCase();
      final path = temporary.absolute.path.toLowerCase();
      if (!path.startsWith('$root${Platform.pathSeparator}') ||
          !temporary.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('yinwei-r2-smoke-')) {
        throw StateError('Unexpected fixture cleanup path');
      }
      await temporary.delete(recursive: true);
      expect(consoleErrors, 0,
          reason: 'Packaged runtime reported console errors');
    }
  },
      skip: executable == null || !Platform.isWindows
          ? 'Requires an explicitly supplied isolated Windows release bundle'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
