import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/ios_remote_live_session.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('received, accepted and native played counts are distinct', () async {
    const channel = MethodChannel('capture-output-counters');
    var writes = 0;
    var played = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'writeRemoteReturn') {
        return {'accepted': ++writes == 1};
      }
      if (call.method == 'getRemoteReturnStatus') {
        return {'ready': true, 'played': played};
      }
      return null;
    });
    final session = IosRemoteLiveSession(channel: channel)..active = true;
    session.acceptReturnAudio(Uint8List(64));
    session.acceptReturnAudio(Uint8List(64));
    await Future<void>.delayed(Duration.zero);
    expect(session.receivedChunks, 2);
    expect(session.outputChunks, 1);
    expect(session.outputDrops, 1);
    expect(session.playedChunks, 0);
    played = 1;
    await session.refreshOutputStatus();
    expect(session.playedChunks, 1);
    await session.stop();
    session.acceptReturnAudio(Uint8List(64));
    expect(session.receivedChunks, 2);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('late native playback status after stop cannot change counters',
      () async {
    const channel = MethodChannel('capture-stale-output');
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getRemoteReturnStatus') {
        entered.complete();
        return response.future;
      }
      return null;
    });
    final session = IosRemoteLiveSession(channel: channel)..active = true;
    final polling = session.refreshOutputStatus();
    await entered.future;
    await session.stop();
    response.complete({'ready': true, 'played': 99});
    await polling;
    expect(session.playedChunks, 0);
    expect(session.active, false);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native output interruption is distinct from capture failure', () async {
    const channel = MethodChannel('capture-output-interruption');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'getRemoteReturnStatus'
                ? {'ready': false}
                : null);
    final session = IosRemoteLiveSession(channel: channel)..active = true;
    await session.refreshOutputStatus();
    expect(session.active, false);
    expect(session.status, contains('iPad output stopped'));
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('missing group and missing extension retain distinct native messages',
      () async {
    const channel = MethodChannel('capture-start-errors');
    for (final error in [
      PlatformException(
          code: 'app_group_unavailable', message: 'Group unavailable'),
      PlatformException(
          code: 'broadcast_extension_missing',
          message: 'Broadcast extension missing'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getRemoteIPCPath') throw error;
        return null;
      });
      final session = IosRemoteLiveSession(channel: channel)..signedIn = true;
      await session.start(routingVerified: true);
      expect(session.status, error.message);
      expect(session.active, false);
      session.dispose();
      await Future<void>.delayed(Duration.zero);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Uint8List packet({bool gap = false}) {
    final bytes = Uint8List(1936);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x31434e59, Endian.little);
    data.setUint32(4, 48000, Endian.little);
    data.setUint32(8, 480, Endian.little);
    data.setUint32(12, gap ? 1 : 0, Endian.little);
    for (var i = 0; i < 960; ++i) {
      data.setInt16(16 + i * 2, i - 480, Endian.little);
    }
    return bytes;
  }

  test('missing picker extension cleans up a prepared live session', () async {
    const channel = MethodChannel('capture-picker-start-error');
    final path =
        '${Directory.systemTemp.path.replaceAll('\\', '/')}/capture-picker/yw.sock';
    var stops = 0;
    int? port;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getRemoteIPCPath') return path;
      if (call.method == 'showBroadcastPicker') {
        throw PlatformException(
            code: 'broadcast_extension_missing',
            message: 'Broadcast extension missing');
      }
      if (call.method == 'stopRemoteReturn') ++stops;
      return null;
    });
    final session = IosRemoteLiveSession(
      channel: channel,
      probe: ReplayKitAudioProbe.create(isIOS: true, channel: channel),
      bindIPC: (_) async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        port = server.port;
        return server;
      },
    )..signedIn = true;
    await session.start(routingVerified: true);
    expect(session.status, 'Broadcast extension missing');
    expect(session.active, false);
    expect(stops, 1);
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port!),
        throwsA(isA<SocketException>()));
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native PCM IPC survives arbitrary fragmentation and coalescing', () {
    final received = <Int16List>[];
    final gaps = <bool>[];
    final parser = IosCapturePCMParser((pcm, gap) {
      received.add(pcm);
      gaps.add(gap);
    });
    final bytes = Uint8List.fromList([...packet(gap: true), ...packet()]);
    for (var i = 0; i < bytes.length; i += 13) {
      parser.add(
          Uint8List.sublistView(bytes, i, (i + 13).clamp(0, bytes.length)));
    }
    expect(received.length, 2);
    expect(gaps, [true, false]);
    expect(received.first.first, -480);
    expect(received.last.last, 479);
    var many = 0;
    final bounded = IosCapturePCMParser((_, __) {
      ++many;
    });
    bounded
        .add(Uint8List.fromList([for (var i = 0; i < 100; ++i) ...packet()]));
    expect(many, 100);
  });
  test('invalid IPC headers never deliver PCM', () {
    for (final offset in [0, 4, 8, 12]) {
      final parser =
          IosCapturePCMParser((_, __) => fail('Invalid IPC delivered'));
      final bytes = packet();
      ByteData.sublistView(bytes).setUint32(offset, 999, Endian.little);
      expect(() => parser.add(bytes), throwsFormatException);
    }
  });
  test('no capture or output activation before sign-in and routing acceptance',
      () async {
    const channel = MethodChannel('r2-test-native');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      ++calls;
      return null;
    });
    final session = IosRemoteLiveSession(channel: channel);
    await session.start(routingVerified: false);
    await session.start(routingVerified: true);
    expect(calls, 0);
    expect(session.active, false);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('stop during output preparation cannot activate or reopen capture',
      () async {
    const channel = MethodChannel('r2-cancel-prepare');
    final entered = Completer<void>(), release = Completer<void>();
    var prepares = 0, stops = 0;
    final path =
        '${Directory.systemTemp.path.replaceAll('\\', '/')}/r2-${DateTime.now().microsecondsSinceEpoch}/yw.sock';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getRemoteIPCPath') return path;
      if (call.method == 'prepareRemoteReturn') {
        ++prepares;
        entered.complete();
        await release.future;
      }
      if (call.method == 'stopRemoteReturn') ++stops;
      return null;
    });
    final session = IosRemoteLiveSession(
        channel: channel,
        bindIPC: (_) => ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
      ..signedIn = true;
    final starting = session.start(routingVerified: true);
    await entered.future;
    await session.stop();
    expect(session.busy, true);
    await session.start(routingVerified: true);
    expect(prepares, 1);
    release.complete();
    await starting;
    expect(session.active, false);
    expect(session.busy, false);
    expect(stops, 1);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('late IPC bind after stop closes its socket without preparing output',
      () async {
    const channel = MethodChannel('r2-cancel-bind');
    final entered = Completer<void>();
    final bind = Completer<ServerSocket>();
    var prepares = 0;
    final path =
        '${Directory.systemTemp.path.replaceAll('\\', '/')}/r2-${DateTime.now().microsecondsSinceEpoch}/yw.sock';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getRemoteIPCPath') return path;
      if (call.method == 'prepareRemoteReturn') ++prepares;
      return null;
    });
    final session = IosRemoteLiveSession(
        channel: channel,
        bindIPC: (_) {
          entered.complete();
          return bind.future;
        })
      ..signedIn = true;
    final starting = session.start(routingVerified: true);
    await entered.future;
    await session.stop();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    bind.complete(server);
    await starting;
    expect(session.active, false);
    expect(prepares, 0);
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()));
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
