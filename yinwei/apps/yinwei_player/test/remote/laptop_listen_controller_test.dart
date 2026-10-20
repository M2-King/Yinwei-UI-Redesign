import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/listen_stream_source.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_owner_client.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

import 'fake_output_source.dart';

/// Records what the iPad output would play and show.
class _FakeOpus implements ListenOpusEncoder {
  @override
  bool setBitrate(int bitrate) => true;
  @override
  Uint8List? encode(Float32List pcm) => Uint8List.fromList([0xfc, 9, 9]);
  @override
  void reset() {}
  @override
  void close() {}
}

class FakeListenOutput implements LaptopListenOutput {
  int prepared = 0, stopped = 0, written = 0;
  bool opus = false;
  final magics = <int>[];
  final rates = <int>[];
  final nowPlaying = <String>[];
  bool hidden = false;
  void Function(String)? handler;

  @override
  Future<void> prepare() async => ++prepared;
  @override
  Future<void> newStream(int sampleRate) async => rates.add(sampleRate);
  @override
  Future<bool> write(Uint8List packet) async {
    ++written;
    magics.add(ByteData.sublistView(packet).getUint32(0, Endian.little));
    return true;
  }

  @override
  Future<bool> supportsOpus() async => opus;

  @override
  Future<Map<String, dynamic>> status() async =>
      {'ready': true, 'interrupted': false, 'played': written, 'bufferMs': 160};
  @override
  Future<void> stop() async => ++stopped;
  @override
  Future<void> showNowPlaying(
      {required String title,
      required String artist,
      required bool playing}) async {
    hidden = false;
    nowPlaying.add('$title|$artist|$playing');
  }

  @override
  Future<void> hideNowPlaying() async => hidden = true;
  @override
  void setRemoteCommandHandler(void Function(String action)? value) =>
      handler = value;
}

Future<void> until(bool Function() done, {int seconds = 8}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const password = 'generated-fixture-password';
  late RemoteGateway gateway;
  late EngineController engine;
  late AppSessionCoordinator coordinator;
  late FakeListenOutput output;
  late LaptopListenController listen;
  late DateTime now;
  var laptopOpus = false;
  var live = false, livePlaying = true, liveSource = 'Music';
  final media = <String>[];
  final liveCalls = <String>[];
  RemoteFailure? startFailure;

  setUp(() async {
    laptopOpus = false;
    startFailure = null;
    live = false;
    livePlaying = true;
    liveSource = 'Music';
    media.clear();
    liveCalls.clear();
    now = DateTime.now();
    final salt = List<int>.generate(16, (i) => i);
    final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    engine = EngineController(engine: MockEngine());
    coordinator = AppSessionCoordinator(
      controller: engine,
      spatial: SpatialRuntimeAdapter()..bootstrap(engine.params),
      nativeBackend: true,
      now: () => now,
      liveRunning: () => live,
      liveSnapshot: () => {
        'source': liveSource,
        'title': 'Song',
        'captureHealthy': true,
        'playing': livePlaying,
      },
      applyLiveParams: (p) => engine.setParamsAcknowledged(p),
      applyLiveMode: (m) async => engine.setMode(m),
      liveMedia: (action) async => media.add(action),
      startLive: () async {
        liveCalls.add('start');
        if (startFailure != null) throw startFailure!;
        live = true;
      },
      stopLive: () async {
        liveCalls.add('stop');
        live = false;
      },
    );
    gateway = RemoteGateway(
      auth: RemoteAuth(RemoteAccount(
          username: 'fixture-owner',
          salt: base64UrlEncode(salt),
          hash: base64UrlEncode(await key.extractBytes()),
          iterations: 10)),
      coordinator: coordinator,
      audioTap: FakeOutputSource(),
      liveAudioTap: FakeOutputSource(),
      createOpusEncoder: () => laptopOpus ? _FakeOpus() : null,
      loadAsset: (_) async => Uint8List.fromList(utf8.encode('<html></html>')),
    );
    await gateway.start();
    output = FakeListenOutput();
    listen = LaptopListenController(
      output: output,
      resolveEntry: (_) async => gateway.origin,
      clientFor: (origin) =>
          RemoteOwnerClient(origin: origin, allowLoopbackForTests: true),
      retryDelay: const Duration(milliseconds: 50),
      leaseRenewal: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    listen.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await gateway.close();
    engine.dispose();
  });

  Future<void> signIn() async {
    await listen.signIn('https://entry.example/', 'fixture-owner', password);
    expect(listen.signedIn, isTrue, reason: listen.status);
    await until(() => listen.connected);
  }

  test('a wrong password is reported and nothing stays signed in', () async {
    await listen.signIn('https://entry.example/', 'fixture-owner', 'wrong');
    expect(listen.signedIn, isFalse);
    expect(listen.status, contains('rejected'));
  });

  test('plays the laptop stream, acknowledging it, and shows now playing',
      () async {
    await signIn();
    await listen.startListening();
    expect(output.prepared, 1);
    expect(output.handler, isNotNull);
    expect(listen.hasControl, isTrue);
    await until(() => listen.audioConnected && output.written > 0);
    expect(listen.audioSource, 'file');
    // 64 unacknowledged packets fill the laptop's window in ~0.7 s; a steady
    // stream past that proves the acknowledgements arrive.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(output.written, greaterThan(90));
    expect(output.rates, [48000]);
    expect(output.nowPlaying.last, contains('Yinwei laptop'));
    final diagnostics = listen.audioDiagnostics();
    expect((diagnostics['arrival'] as Map)['samples'], greaterThan(0));
    expect((diagnostics['nativeWriteRoundTrip'] as Map)['p95Ms'], isNotNull);
    expect(diagnostics['bufferHistory'], isNotEmpty);
    expect(diagnostics.containsKey('snapshot'), isFalse);

    await listen.stopListening();
    expect(output.stopped, 1);
    expect(output.hidden, isTrue);
    expect(output.handler, isNull);
    final written = output.written;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(output.written, written);
  });

  test('Start on laptop and listen starts Live and follows its stream',
      () async {
    await signIn();
    await listen.startListening(startLive: true);
    expect(liveCalls, ['start']);
    // The file stream is replaced by the Live stream.
    await until(() => listen.audioSource == 'live' && output.rates.isNotEmpty);
    final written = output.written;
    await until(() => output.written > written + 20);
    expect(output.nowPlaying.last, 'Song|Music · Yinwei laptop|true');
  });

  test('lock-screen buttons control the laptop music', () async {
    live = true;
    await signIn();
    await listen.startListening();
    output.handler!('next');
    await until(() => media.contains('next'));
    output.handler!('toggle'); // playing → pause
    await until(() => media.contains('pause'));
    livePlaying = false;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    output.handler!('toggle'); // paused → play
    await until(() => media.contains('play'));
    output.handler!('previous');
    await until(() => media.contains('previous'));
  });

  test('lock-screen play starts Live when it is off', () async {
    await signIn();
    await listen.startListening();
    output.handler!('play');
    await until(() => liveCalls.contains('start'));
    expect(media, isEmpty);
  });

  test('control comes back after a lapse but not after a laptop takeover',
      () async {
    await signIn();
    expect(await listen.takeControl(), isTrue);
    // The lease lapsed (paused app, network drop): re-taken on its own.
    now = now.add(const Duration(seconds: 31));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(listen.hasControl, isTrue);
    expect(
        await listen.command(
            'point.set', {'azimuthDeg': 40, 'elevationDeg': 0, 'distanceM': 2}),
        isTrue);

    // Someone at the laptop takes over: no automatic re-take.
    coordinator.takeLocalControl();
    await until(() => !listen.hasControl);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(listen.hasControl, isFalse);
    expect(listen.notice, contains('took control'));
    expect(await listen.takeControl(), isTrue);
  });

  test('the laptop could not open its music app: control is kept', () async {
    liveSource = '';
    await signIn();
    expect(await listen.takeControl(), isTrue);
    for (final code in ['music_app_no_song', 'music_app_open_failed']) {
      startFailure = RemoteFailure(code);
      expect(await listen.command('live.start'), isFalse);
      expect(listen.hasControl, isTrue, reason: code);
      expect(listen.notice, LaptopListenController.failureText(code));
      expect(listen.notice, isNot(contains('_')),
          reason: 'explained, not a code');
    }
  });

  test('a laptop song change does not cost control or a command', () async {
    live = true;
    await signIn();
    expect(await listen.takeControl(), isTrue);
    // The music app changes by itself just before the tap: the command
    // carries an old state version, is refreshed and sent again.
    liveSource = 'Other app';
    expect(await listen.command('media.next'), isTrue);
    expect(listen.hasControl, isTrue);
    expect(media, ['next']);
  });

  test('an Opus iPad gets High from the laptop and switches without reconnecting',
      () async {
    laptopOpus = true;
    output.opus = true;
    await signIn();
    await listen.startListening();
    await until(() => listen.audioConnected && output.written > 5);
    expect(listen.opusAvailable, isTrue);
    expect(listen.soundQuality, ListenQuality.high);
    expect(listen.streamQuality, ListenQuality.high);
    expect(output.magics.toSet(), {ynoMagic});
    listen.setSoundQuality(ListenQuality.lossless);
    expect(listen.streamQuality, ListenQuality.lossless);
    await until(() => output.magics.last == ynwMagic);
    listen.setSoundQuality(ListenQuality.max);
    await until(() => output.magics.last == ynoMagic);
    expect(output.rates, [48000]); // one stream throughout: no reconnect
    expect(listen.audioDiagnostics()['streamQuality'], 'max');
  });

  test('without the laptop encoder the stream stays uncompressed', () async {
    output.opus = true;
    await signIn();
    await listen.startListening();
    await until(() => listen.audioConnected && output.written > 5);
    expect(listen.opusAvailable, isFalse);
    expect(listen.streamQuality, ListenQuality.lossless);
    expect(output.magics.toSet(), {ynwMagic});
    listen.setSoundQuality(ListenQuality.max); // remembered, not sent
    expect(listen.streamQuality, ListenQuality.lossless);
  });

  test('Opus packet headers are checked too', () {
    final packet = Uint8List(56 + 700);
    final data = ByteData.sublistView(packet);
    data.setUint32(0, ynoMagic, Endian.little);
    data.setUint32(4, 1, Endian.little);
    data.setUint64(16, 4, Endian.little);
    data.setUint32(32, 48000, Endian.little);
    data.setUint32(36, 960, Endian.little);
    final header = YnwPacketHeader.parse(packet)!;
    expect([header.opus, header.sequence, header.frames], [true, 4, 960]);
    data.setUint32(32, 44100, Endian.little);
    expect(YnwPacketHeader.parse(packet), isNull);
    data.setUint32(32, 48000, Endian.little);
    expect(YnwPacketHeader.parse(Uint8List(56 + 1501)..setRange(0, 56, packet)),
        isNull);
  });

  test('packet headers are checked before playing', () {
    final packet = Uint8List(56 + 480 * 8);
    final data = ByteData.sublistView(packet);
    data.setUint32(0, 0x31574e59, Endian.little);
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, 3, Endian.little);
    data.setUint64(16, 9, Endian.little);
    data.setUint32(32, 44100, Endian.little);
    data.setUint32(36, 480, Endian.little);
    final header = YnwPacketHeader.parse(packet)!;
    expect([header.epoch, header.sequence, header.sampleRate], [3, 9, 44100]);
    expect(YnwPacketHeader.parse(packet.sublist(0, 100)), isNull);
    data.setUint32(0, 0, Endian.little);
    expect(YnwPacketHeader.parse(packet), isNull);
  });
}
