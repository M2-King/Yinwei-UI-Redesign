import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/ios_laptop_listen_output.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';

import '../fixtures/listen_room_audio.dart';

class _SilentOutput implements LaptopListenOutput {
  @override
  Future<void> prepare() async {}
  @override
  Future<void> newStream(int sampleRate) async {}
  @override
  Future<bool> write(Uint8List packet) async => true;
  @override
  Future<bool> supportsOpus() async => false;
  @override
  Future<Map<String, dynamic>> status() async => {'ready': true};
  @override
  Future<void> stop() async {}
  @override
  Future<void> showNowPlaying(
      {required String title,
      required String artist,
      required bool playing}) async {}
  @override
  Future<void> hideNowPlaying() async {}
  @override
  void setRemoteCommandHandler(void Function(String action)? handler) {}
}

/// A listening session that records what the bridge asks of it.
class FakeSession extends LaptopListenController {
  FakeSession({LaptopListenOutput? output})
      : super(output: output ?? _SilentOutput());

  bool control = false, signed = true, takeWorks = true, commandWorks = true;
  final calls = <String>[];
  // A start that is still on its way to the laptop.
  Future<void>? startGate;
  Future<Map<String, dynamic>>? browseGate;
  Map<String, dynamic>? browseRequest;

  @override
  Future<Map<String, dynamic>> browseSoda(Map<String, dynamic> request) async {
    browseRequest = request;
    return await browseGate ?? {'revision': 'r1', 'lists': []};
  }

  @override
  bool get hasControl => control;
  @override
  bool get signedIn => signed;

  @override
  Future<bool> takeControl() async {
    calls.add('take');
    control = takeWorks;
    notice =
        takeWorks ? null : LaptopListenController.failureText('control_busy');
    notifyListeners();
    return takeWorks;
  }

  @override
  Future<bool> command(String type,
      [Map<String, dynamic> payload = const {}]) async {
    calls.add('$type ${jsonEncode(payload)}');
    notice =
        commandWorks ? 'Applied on the laptop.' : 'Orbit is off in 2.0 mode.';
    return commandWorks;
  }

  @override
  Future<void> startListening({bool startLive = false}) async {
    calls.add('listen startLive=$startLive');
    await startGate;
  }

  @override
  Future<void> stopListening({String? message}) async => calls.add('stop');
  @override
  Future<void> signOut() async => calls.add('signOut');

  void set(void Function(FakeSession s) change) {
    change(this);
    notifyListeners();
  }
}

Map<String, dynamic> snapshot({
  bool liveRunning = true,
  String source = '汽水音乐',
  bool remoteLive = true,
  bool liveMedia = true,
  bool remoteArray = true,
  bool pointControl = true,
  bool controlHeld = false,
  bool hasFile = false,
  String openApp = '',
  double? liveAz,
  String startStage = '',
}) =>
    {
      'liveRunning': liveRunning,
      'controlHeld': controlHeld,
      'capabilities': {
        'remoteLive': remoteLive,
        'liveMedia': liveMedia,
        'remoteArray': remoteArray,
        'pointControl': pointControl,
      },
      'live': {
        'source': source,
        'title': '晴天',
        'playing': true,
        'openApp': openApp,
        'azimuthDeg': liveAz,
        'startStage': startStage,
      },
      'track': {'title': 'Demo.wav', 'artist': 'Yinwei', 'hasFile': hasFile},
      'transport': {'playing': false},
      'spatialMode': {'array': 'point', 'motion': 'orbit', 'orbitHz': 0.4},
      'pose': {'azimuthDeg': 35.0, 'elevationDeg': 20.0, 'distanceM': 3.2},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSession session;
  late ListenRoomBridge bridge;
  late List<String> scripts;

  test('music browsing is on demand; late response after close is discarded',
      () async {
    final s = FakeSession()..snapshot = snapshot();
    s.snapshot!['capabilities']['sodaLibrary'] = true;
    final gate = Completer<Map<String, dynamic>>();
    s.browseGate = gate.future;
    final output = <String>[];
    final b = ListenRoomBridge(session: s, run: (v) async => output.add(v));
    expect(b.state()['music'], true);
    final reading =
        b.handle('{"t":"musicBrowse","request":1,"list":"list_1","offset":50}');
    await Future<void>.delayed(Duration.zero);
    expect(s.browseRequest, {'list': 'list_1', 'offset': 50});
    expect(s.calls, isEmpty,
        reason: 'browsing does not acquire control or start Live');
    await b.handle('{"t":"musicClose"}');
    gate.complete({'revision': 'r1', 'lists': []});
    await reading;
    expect(output.where((v) => v.startsWith('YinweiListen.music')), isEmpty);
    b.dispose();
    s.dispose();
  });

  test('chosen song has a dedicated lease command and accepts no arbitrary URI',
      () async {
    final s = FakeSession()..snapshot = snapshot();
    s.snapshot!['capabilities']['sodaLibrary'] = true;
    final b = ListenRoomBridge(session: s, run: (_) async {});
    await b.handle(
        '{"t":"musicPlay","list":"list1","snapshot":"snap1","track":"row1","revision":"r1"}');
    expect(s.calls, [
      'take',
      'library.play {"list":"list1","snapshot":"snap1","track":"row1","revision":"r1"}'
    ]);
    s.calls.clear();
    await b.handle('{"t":"musicPlay","uri":"luna://arbitrary"}');
    expect(s.calls, isEmpty);
    s.signed = false;
    expect(b.state()['music'], false);
    b.dispose();
    s.dispose();
  });

  test('speaker state and intents keep the page revision through commands',
      () async {
    final s = FakeSession()..control = true;
    final b = ListenRoomBridge(session: s, run: (_) async {});
    s.snapshot = snapshot()..['capabilities']['remoteSpeakers'] = true;
    s.snapshot!['arrayState'] = {
      'revision': 12,
      'selectedIndex': 2,
      'maxSpeakers': 8,
      'matrixLinked': true,
      'speakers': [
        {
          'index': 2,
          'label': '3',
          'az': 40,
          'el': 0,
          'dist': 2,
          'gainDb': 0,
          'mute': false,
          'feed': 'mid'
        }
      ]
    };
    expect(b.state()['arrayRevision'], 12);
    expect(b.state()['selectedSpeakerIndex'], 2);
    expect(b.state()['matrixLinked'], true);
    // A newer snapshot must not replace the old gesture's revision.
    await b.handle(
        '{"t":"speakerPlace","arrayRevision":11,"index":2,"az":50,"el":10,"dist":3}');
    expect(s.calls.single, startsWith('array.speaker.set '));
    expect(s.calls.single, contains('"arrayRevision":11'));
    s.calls.clear();
    await b.handle('{"t":"speakerAdd"}');
    await b.handle('{"t":"speakerRemove","arrayRevision":12,"index":8}');
    expect(s.calls, isEmpty);
    b.dispose();
    s.dispose();
  });

  ListenRoomBridge make({bool playerPlaying = false, Duration? interval}) {
    final b = ListenRoomBridge(
      session: session,
      run: (script) async => scripts.add(script),
      localPlayerPlaying: () => playerPlaying,
      minInterval: interval ?? const Duration(milliseconds: 100),
    );
    b.attach();
    return b;
  }

  Map<String, dynamic> lastState() => jsonDecode(scripts
      .lastWhere((s) => s.startsWith('YinweiListen.apply('))
      .replaceFirst('YinweiListen.apply(', '')
      .replaceFirst(RegExp(r'\)$'), '')) as Map<String, dynamic>;
  List<String> toasts() => [
        for (final s in scripts)
          if (s.startsWith('YinweiListen.toast('))
            jsonDecode(s.substring(19, s.length - 1)) as String
      ];

  setUp(() {
    session = FakeSession()
      ..snapshot = snapshot()
      ..connected = true;
    scripts = [];
    bridge = make();
  });
  tearDown(() => bridge.dispose());

  test('copies bounded audio diagnostics locally without laptop commands',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<String, dynamic>? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = jsonDecode((call.arguments as Map)['text'] as String)
            as Map<String, dynamic>;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await bridge.handle('{"t":"ready"}');
    await bridge.handle('{"t":"copyAudioDiagnostics"}');
    expect(copied?['schema'], 1);
    expect(copied?['bufferHistory'], isEmpty);
    expect(copied?.containsKey('snapshot'), isFalse);
    expect(session.calls, isEmpty);
    expect(toasts(), contains('Audio diagnostics copied'));
  });

  group('native P3 additions', () {
    const player = MethodChannel(ReplayKitAudioProbe.channelName);
    const audio = MethodChannel(IosLaptopListenOutput.audioChannel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late IosLaptopListenOutput output;
    late List<MethodCall> nativeCalls;

    setUp(() async {
      bridge.dispose();
      nativeCalls = [];
      for (final channel in [player, audio]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call);
          return call.method == 'writeRemoteReturn' ? {'accepted': true} : null;
        });
      }
      output = IosLaptopListenOutput();
      session = FakeSession(output: output)
        ..snapshot = snapshot()
        ..connected = true
        ..listening = true
        ..audioConnected = true;
      bridge = make();
      await output.prepare();
    });
    tearDown(() async {
      bridge.dispose();
      await output.stop();
      messenger.setMockMethodCallHandler(player, null);
      messenger.setMockMethodCallHandler(audio, null);
    });

    testWidgets(
        'volume reaches only the iPad and survives reopening the bridge',
        (tester) async {
      await bridge.handle('{"t":"ready"}');
      await bridge.handle('{"t":"volume","v":0.42}');
      expect(nativeCalls.last.method, 'setRemoteReturnVolume');
      expect(nativeCalls.last.arguments, {'volume': 0.42});
      expect(session.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(lastState()['volume'], 0.42);
      final count = nativeCalls.length;
      for (final value in ['null', '"loud"', '1e309']) {
        await bridge.handle('{"t":"volume","v":$value}');
      }
      expect(nativeCalls.length, count);
      bridge.dispose();
      bridge = make();
      await bridge.handle('{"t":"ready"}');
      expect(lastState()['volume'], 0.42);
    });

    testWidgets('failed volume is reported and the confirmed value re-sent',
        (tester) async {
      await bridge.handle('{"t":"ready"}');
      await bridge.handle('{"t":"volume","v":0.4}');
      messenger.setMockMethodCallHandler(player, (call) async {
        if (call.method == 'setRemoteReturnVolume') {
          throw PlatformException(code: 'failed');
        }
        return null;
      });
      await bridge.handle('{"t":"volume","v":0.8}');
      expect(lastState()['volume'], 0.4);
      expect(toasts().last, 'Could not change the iPad volume');
      bridge.dispose();
    });

    testWidgets('packet peaks reach the page at most ten times a second',
        (tester) async {
      await bridge.handle('{"t":"ready"}');
      scripts.clear();
      for (var i = 0; i < 12; ++i) {
        await output.write(listenRoomPacket([0, (i + 1) / 16]));
      }
      expect(scripts, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(scripts.length, 1);
      expect(lastState()['level'], greaterThan(0));
      session.interrupted = true;
      expect(bridge.level, 0);
      session.interrupted = false;
      session.audioConnected = false;
      expect(bridge.level, 0);
      session.audioConnected = true;
      session.listening = false;
      expect(bridge.level, 0);
      bridge.dispose();
      scripts.clear();
      await output.stop();
      await tester.pump(const Duration(seconds: 1));
      expect(scripts, isEmpty,
          reason: 'disposed bridge detached its meter listener');
    });
  });

  test('AirPlay bounds notify only on change and reject invalid rectangles',
      () async {
    var changes = 0;
    bridge.onAirplayRectChanged = () => ++changes;
    await bridge.handle('{"t":"rects","airplay":[100.4,200,40,40]}');
    expect(bridge.airplayRect, [100, 200, 40, 40]);
    expect(changes, 1);
    await bridge.handle('{"t":"rects","airplay":[100.4,200,40,40]}');
    expect(changes, 1);
    for (final rect in [
      'null',
      '[1,2,3]',
      '[1,2,0,40]',
      '[-1,2,40,40]',
      '[1,2,40,-1]',
      '[1e309,2,40,40]',
      '[1e30,2,40,40]',
      '["x",2,40,40]'
    ]) {
      await bridge.handle('{"t":"rects","airplay":$rect}');
      expect(bridge.airplayRect, isNull);
    }
    expect(changes, 2);
    await bridge.handle('{"t":"rects","airplay":[10,20,40,40]}');
    bridge.pageReloaded();
    expect(bridge.airplayRect, isNull);
    expect(changes, 4);
    bridge.dispose();
    await bridge.handle('{"t":"rects","airplay":[10,20,40,40]}');
    expect(changes, 4);
  });

  group('state for the page', () {
    test('maps a Live snapshot to version-1 state', () {
      final s = bridge.state();
      expect(s['v'], 1);
      expect(s['laptop'], 'your laptop');
      expect(s['source'], '汽水音乐');
      expect(s['live'], true);
      expect(s['playing'], true, reason: 'Live uses live.playing');
      expect(s['track'], {'title': '晴天', 'artist': ''});
      expect(s['mode'], 'point');
      expect(s['motion'], 'orbit');
      expect(
          [s['az'], s['el'], s['dist'], s['orbitHz']], [35.0, 20.0, 3.2, 0.4]);
      expect(s['notice'], 'none');
      expect(s['connection'], 'connected');
    });

    test('the laptop’s own player: file title and artist, its transport', () {
      session.snapshot =
          snapshot(liveRunning: false, hasFile: true, source: '');
      final s = bridge.state();
      expect(s['track'], {'title': 'Demo.wav', 'artist': 'Yinwei'});
      expect(s['playing'], false);
      expect(s['source'], 'the Yinwei player');
      expect(s['notice'], 'none', reason: 'a file plays without a music app');
    });

    test('listening is off, connecting, then on', () {
      expect(bridge.state()['listening'], 'off');
      session.listening = true;
      expect(bridge.state()['listening'], 'connecting');
      session.audioConnected = true;
      expect(bridge.state()['listening'], 'on');
    });

    test('lost only after the laptop was reached once', () {
      session.connected = false;
      expect(bridge.state()['notice'], 'none', reason: 'still signing in');
      session.connected = true;
      bridge.state();
      session.connected = false;
      final s = bridge.state();
      expect([s['notice'], s['connection']], ['lost', 'reconnecting']);
    });

    test('control: another device or the laptop holds it', () {
      expect(bridge.state()['control'], 'mine');
      session.snapshot = snapshot(controlHeld: true);
      expect(bridge.state()['control'], 'other');
      session.control = true;
      expect(bridge.state()['control'], 'mine');
      session
        ..control = false
        ..snapshot = snapshot()
        ..notice = LaptopListenController.failureText('control_taken');
      expect(bridge.state()['control'], 'other');
    });

    test('notices: no music app, phone call, Safari listening', () {
      session.snapshot = snapshot(liveRunning: false, source: '');
      expect(bridge.state()['notice'], 'noapp');
      session.notice = LaptopListenController.failureText('no_music_app');
      expect(bridge.state()['notice'], 'noapp');
      session.snapshot = snapshot(liveRunning: false);
      expect(bridge.state()['notice'], 'none',
          reason: 'a music app opened on the laptop: Start works again');
      session.snapshot = snapshot();
      expect(bridge.state()['notice'], 'none');
      session
        ..notice = null
        ..interrupted = true;
      expect(bridge.state()['notice'], 'interrupted');
      session
        ..interrupted = false
        ..listening = true
        ..status =
            'Another device is listening (Safari?) · stop it there. Retrying…';
      expect(bridge.state()['notice'], 'busy');
    });

    test('no music app open: the app the laptop opens on Start', () {
      session.snapshot =
          snapshot(liveRunning: false, source: '', openApp: '汽水音乐');
      expect(bridge.state()['opens'], '汽水音乐');
      expect(bridge.state()['notice'], 'none', reason: 'Start can open it');
      session.notice = LaptopListenController.failureText('no_music_app');
      expect(bridge.state()['notice'], 'noapp',
          reason: 'the laptop could not open it after all');
      session.notice = null;
      session.snapshot =
          snapshot(liveRunning: false, source: '汽水音乐', openApp: '汽水音乐');
      expect(bridge.state()['opens'], isNull, reason: 'a music app is open');
      session.snapshot = snapshot(source: '', openApp: '汽水音乐');
      expect(bridge.state()['opens'], isNull, reason: 'Live is running');
      session.snapshot = snapshot(
          liveRunning: false, source: '', openApp: '汽水音乐', remoteLive: false);
      expect(bridge.state()['opens'], isNull,
          reason: 'this laptop cannot start Live remotely');
      session.snapshot = snapshot(liveRunning: false, source: '');
      expect(bridge.state()['opens'], isNull, reason: 'an older laptop');
      expect(bridge.state()['notice'], 'noapp');
    });

    test('orbit: the light follows where the sound is now', () {
      session.snapshot = snapshot(liveAz: 200);
      expect(bridge.state()['az'], -160.0,
          reason: "the Live engine's heading, wrapped to ±180");
      session.snapshot = snapshot(liveAz: 200)
        ..['spatialMode'] = {
          'array': 'point',
          'motion': 'fixed',
          'orbitHz': 0.4
        };
      expect(bridge.state()['az'], 35.0, reason: 'Fixed: the set direction');
      session.snapshot = snapshot(liveAz: 200)
        ..['spatialMode'] = {
          'array': 'stereo2',
          'motion': 'orbit',
          'orbitHz': 0.4
        };
      expect(bridge.state()['az'], 35.0, reason: 'no orbit in 2.0');
      session.snapshot = snapshot(liveRunning: false)
        ..['transport'] = {'playing': true}
        ..['telemetry'] = {'azimuthDeg': 120.0};
      expect(bridge.state()['az'], 120.0, reason: "the file player's heading");
      session.snapshot = snapshot();
      expect(bridge.state()['az'], 35.0, reason: 'an older laptop sends none');
    });

    test('start progress: asking, the laptop step, then audio', () async {
      session.snapshot = snapshot(liveRunning: false, startStage: 'opening');
      expect(bridge.state()['progress'], 'opening');
      session.snapshot = snapshot(liveRunning: false);
      expect(bridge.state()['progress'], isNull);
      final gate = Completer<void>();
      session.startGate = gate.future;
      final handling = bridge.handle('{"t":"listen","startLive":true}');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.state()['progress'], 'asking',
          reason: 'before the laptop reports a step');
      session.snapshot = snapshot(liveRunning: false, startStage: 'pressing');
      expect(bridge.state()['progress'], 'pressing');
      gate.complete();
      await handling;
      session.snapshot = snapshot();
      expect(bridge.state()['progress'], isNull);
      session.set((s) => s
        ..listening = true
        ..audioConnected = false);
      expect(bridge.state()['progress'], 'audio');
      session.set((s) => s.audioConnected = true);
      expect(bridge.state()['progress'], isNull);
    });

    test('song progress: the music app over Live, else the file', () {
      session.snapshot = snapshot()
        ..['capabilities'] = {'remoteLive': true, 'liveSeek': true}
        ..['live'] = {
          'source': '汽水音乐',
          'title': '晴天',
          'positionSec': 83.4,
          'durationSec': 269.0,
        };
      var st = bridge.state();
      expect([st['pos'], st['dur'], st['seekable']], [83.4, 269.0, true]);
      session.snapshot = snapshot()
        ..['capabilities'] = {'remoteLive': true}
        ..['live'] = {'source': '汽水音乐', 'positionSec': 10, 'durationSec': 200};
      expect(bridge.state()['seekable'], isFalse, reason: 'an older laptop');
      session.snapshot = snapshot(liveRunning: false, hasFile: true)
        ..['transport'] = {'playing': true, 'positionMs': 30500}
        ..['track'] = {
          'title': 'Demo.wav',
          'hasFile': true,
          'durationMs': 90000
        };
      st = bridge.state();
      expect([st['pos'], st['dur'], st['seekable']], [30.5, 90.0, true]);
      session.snapshot = snapshot(liveRunning: false);
      expect([bridge.state()['dur'], bridge.state()['seekable']], [0, false],
          reason: 'nothing to show: no bar');
    });

    test('seek: the music app over Live, the file player otherwise', () async {
      session.control = true;
      session.snapshot = snapshot()
        ..['capabilities'] = {'remoteLive': true, 'liveSeek': true};
      await bridge.handle('{"t":"seek","sec":83.5}');
      session.snapshot = snapshot(liveRunning: false, hasFile: true);
      await bridge.handle('{"t":"seek","sec":30.25}');
      await bridge.handle('{"t":"seek","sec":-3}');
      expect(session.calls.where((c) => c.contains('seek')), [
        'media.seek {"positionSec":83.5}',
        'seek {"positionMs":30250}',
      ]);
    });

    test('the room as the whole app: no way back; updates from the menu',
        () async {
      var closed = 0, checks = 0;
      final home =
          ListenRoomBridge(session: session, run: (_) async {}, canClose: false)
            ..onClose = (() => closed++)
            ..onCheckUpdates = (() => checks++);
      expect(home.state()['canClose'], isFalse);
      expect(home.state()['updates'], isTrue);
      await home.handle('{"t":"close"}');
      await home.handle('{"t":"checkUpdates"}');
      expect([closed, checks], [0, 1]);
      expect(bridge.state()['canClose'], isTrue, reason: 'opened from a page');
      expect(bridge.state()['updates'], isFalse);
      home.dispose();
    });

    test('pending: a command on its way keeps what you tapped', () {
      expect(bridge.state()['pending'], isFalse);
      session.pending = true;
      expect(bridge.state()['pending'], isTrue);
    });

    test('positions are clamped to the engine ranges', () {
      session.snapshot = snapshot()
        ..['pose'] = {
          'azimuthDeg': 400,
          'elevationDeg': -120,
          'distanceM': 0.1
        };
      final s = bridge.state();
      expect([s['az'], s['el'], s['dist']], [180.0, -90.0, 0.5]);
    });
  });

  group('sending state', () {
    test('nothing is sent before the page is ready; ready sends it all',
        () async {
      session.set((s) => s.received = 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(scripts, isEmpty);
      await bridge.handle('{"t":"ready","v":1}');
      expect(scripts.single, startsWith('YinweiListen.apply('));
      expect(lastState()['az'], 35.0);
    });

    test('at most once per interval, and only when something changed',
        () async {
      await bridge.handle('{"t":"ready","v":1}');
      scripts.clear();
      for (var i = 0; i < 20; i++) {
        session.set((s) => s.received = i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(scripts.length, lessThanOrEqualTo(1));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(scripts.length, lessThanOrEqualTo(2));
      expect(lastState()['stats']['received'], 19);
      final before = scripts.length;
      session.set((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(scripts.length, before, reason: 'unchanged state is not re-sent');
    });

    test('a reloaded page gets the whole state again after ready', () async {
      await bridge.handle('{"t":"ready","v":1}');
      bridge.pageReloaded();
      scripts.clear();
      session.set((s) => s.received = 5);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(scripts, isEmpty);
      await bridge.handle('{"t":"ready","v":1}');
      expect(lastState()['stats']['received'], 5);
    });
  });

  group('intents from the page', () {
    setUp(() async => bridge.handle('{"t":"ready","v":1}'));

    test('place: takes control first, then point.set with clamped values',
        () async {
      await bridge.handle('{"t":"place","az":400,"el":20,"dist":0.2}');
      expect(session.calls, [
        'take',
        'point.set {"azimuthDeg":180.0,"elevationDeg":20.0,"distanceM":0.5}',
      ]);
      expect(toasts().last, 'Applied on the laptop');
    });

    test(
        'when the laptop has taken control, nothing is sent and the page reverts',
        () async {
      session.notice = LaptopListenController.failureText('control_taken');
      scripts.clear();
      await bridge.handle('{"t":"layout","mode":"stereo2"}');
      expect(session.calls, isEmpty);
      expect(toasts().single, startsWith('Someone at the laptop took control'));
      expect(scripts.any((s) => s.startsWith('YinweiListen.apply(')), isTrue);
    });

    test('a refused command re-sends the laptop’s state', () async {
      session
        ..control = true
        ..commandWorks = false;
      scripts.clear();
      await bridge.handle('{"t":"motion","motion":"orbit","orbitHz":9}');
      expect(
          session.calls.single, 'motion.set {"motion":"orbit","orbitHz":2.0}');
      expect(toasts().last, 'Orbit is off in 2.0 mode');
      expect(scripts.any((s) => s.startsWith('YinweiListen.apply(')), isTrue);
    });

    test('media: Live music-app commands, and play starts Live when it is off',
        () async {
      session.control = true;
      await bridge.handle('{"t":"media","a":"prev"}');
      await bridge.handle('{"t":"media","a":"pause"}');
      session.snapshot = snapshot(liveRunning: false);
      await bridge.handle('{"t":"media","a":"play"}');
      session.snapshot = snapshot(liveMedia: false);
      await bridge.handle('{"t":"media","a":"next"}');
      expect(session.calls,
          ['media.previous {}', 'media.pause {}', 'live.start {}']);
      expect(toasts().last, contains('can’t change songs from here'));
    });

    test('layout needs the laptop’s 2.0 control; place needs point control',
        () async {
      session
        ..control = true
        ..snapshot = snapshot(remoteArray: false, pointControl: false);
      await bridge.handle('{"t":"layout","mode":"stereo2"}');
      await bridge.handle('{"t":"place","az":10,"el":0,"dist":2}');
      expect(session.calls, isEmpty);
      expect(toasts().last, contains('2.0'));
    });

    test(
        'listen starts Live only when asked and possible; waits for the iPad player',
        () async {
      await bridge.handle('{"t":"listen","startLive":true}');
      session.snapshot = snapshot(liveRunning: false);
      await bridge.handle('{"t":"listen","startLive":true}');
      expect(
          session.calls, ['listen startLive=false', 'listen startLive=true']);
      bridge.dispose();
      bridge = make(playerPlaying: true);
      await bridge.handle('{"t":"ready","v":1}');
      session.calls.clear();
      await bridge.handle('{"t":"listen","startLive":false}');
      expect(session.calls, isEmpty);
      expect(toasts().last, 'Pause the iPad’s own player first');
    });

    test('take, stop listening and sign out go to the session', () async {
      await bridge.handle('{"t":"take"}');
      await bridge.handle('{"t":"stopListening"}');
      await bridge.handle('{"t":"signOut"}');
      expect(session.calls, ['take', 'stop', 'signOut']);
      expect(toasts().first, 'You’re in control');
    });

    test('local values, page events and junk', () async {
      String? error;
      var closed = false;
      bridge
        ..onPageError = ((reason) => error = reason)
        ..onClose = (() => closed = true);
      await bridge.handle('{"t":"volume","v":3}');
      await bridge.handle('{"t":"rects","airplay":[1000.4,700,48,48]}');
      await bridge.handle('{"t":"error","msg":"webgl"}');
      await bridge.handle('{"t":"close"}');
      for (final junk in [
        'not json',
        '[1,2]',
        '{"t":5}',
        '{"t":"format_disk"}',
        '{"t":"place","az":"x"}'
      ]) {
        await bridge.handle(junk);
      }
      expect(bridge.volume, 1.0);
      expect(bridge.airplayRect, [1000, 700, 48, 48]);
      expect(error, 'webgl');
      expect(closed, isTrue);
      expect(session.calls, isEmpty);
    });
  });
}
