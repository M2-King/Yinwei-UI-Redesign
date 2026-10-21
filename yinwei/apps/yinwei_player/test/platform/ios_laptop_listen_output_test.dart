import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/ios_laptop_listen_screen.dart';
import 'package:yinwei_player/mobile/mobile_now_playing_header.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/platform/ios_laptop_listen_output.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/state/engine_controller.dart';

import '../fixtures/listen_room_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const player = MethodChannel(ReplayKitAudioProbe.channelName);
  const audio = MethodChannel(IosLaptopListenOutput.audioChannel);
  const nowPlaying = MethodChannel(IosLaptopListenOutput.nowPlayingChannel);
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    for (final channel in [player, audio, nowPlaying]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'writeRemoteReturn' => {'accepted': true},
          'getRemoteReturnStatus' => {'ready': true, 'interrupted': false},
          _ => null,
        };
      });
    }
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(player, null);
    messenger.setMockMethodCallHandler(audio, null);
    messenger.setMockMethodCallHandler(nowPlaying, null);
  });

  test('audio packets reach the iPad player off the main thread', () {
    final swift =
        File('ios/Runner/YinweiReplayKitProbe.swift').readAsStringSync();
    expect(
        swift,
        contains(
            'static let audioName = "${IosLaptopListenOutput.audioChannel}"'));
    expect(swift, contains('taskQueue: messenger.makeBackgroundTaskQueue?()'));
    final player = swift.substring(
        swift.indexOf('private final class YinweiRemoteReturnPlayer'),
        swift.indexOf('final class YinweiListenRoomRoutePickerFactory'));
    expect(
        player, contains('DispatchQueue(label: "dev.yinwei.remote-return")'));
    expect(player, isNot(contains('DispatchQueue.main')),
        reason: 'buffer bookkeeping stays on the audio queue');
    expect(player, isNot(contains('queue: .main')),
        reason: 'interruptions and route changes too');
  });

  test('route configuration and transport fade do not change user volume',
      () async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    await output.setVolume(0.4);
    await output.configureLatency(privateRoute: true);
    await output.setTransportGain(0);
    await output.setTransportGain(1);
    expect(output.volume, 0.4);
    expect(
        calls
            .where((c) => c.method == 'configureListenLatency')
            .single
            .arguments,
        {
          'privateRoute': true,
          'catchUp': IosLaptopListenOutput.experimentalCatchUp
        });
    expect(
        calls
            .where((c) => c.method == 'setListenTransportGain')
            .map((c) => c.arguments),
        [
          {'gain': 0.0},
          {'gain': 1.0}
        ]);
    await output.stop();
  });

  test('uses the argument names the Swift player and lock screen read',
      () async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    await output.newStream(44100);
    expect(await output.write(Uint8List(64)), isTrue);
    expect((await output.status())['ready'], isTrue);
    await output.showNowPlaying(title: 'Song', artist: 'Music', playing: true);
    await output.hideNowPlaying();
    await output.stop();
    expect(calls.map((c) => c.method), [
      'prepareRemoteReturn',
      'setRemoteReturnVolume',
      'resetRemoteReturn',
      'writeRemoteReturn',
      'getRemoteReturnStatus',
      'update',
      'clear',
      'stopRemoteReturn',
    ]);
    expect(calls[0].arguments, {'listen': true});
    expect(calls[1].arguments, {'volume': 1.0});
    expect(calls[2].arguments, {'newStream': true, 'sampleRate': 44100});
    expect(calls[5].arguments,
        {'title': 'Song', 'artist': 'Music', 'playing': true});

    // Swift source agrees on these names.
    final swift =
        File('ios/Runner/YinweiReplayKitProbe.swift').readAsStringSync();
    for (final name in [
      '"listen"',
      '"newStream"',
      '"sampleRate"',
      '"interrupted"',
      'case "setRemoteReturnVolume"',
      'guard listenMode, volume.isFinite else { return }',
      'player.volume = listen ? listenVolume : 1',
      'if listenMode { player.volume = listenVolume * transportGain }',
      '"dev.yinwei/now_playing"',
      'case "update"',
      'case "clear"',
      'case "enable"',
      'case "disable"',
      'invokeMethod("command"',
    ]) {
      expect(swift, contains(name));
    }
  });

  test('local volume is clamped, retained, and applied before streaming',
      () async {
    final output = IosLaptopListenOutput();
    await output.setVolume(0.35);
    expect(calls, isEmpty, reason: 'stopped output must not touch capture');
    await output.prepare();
    expect(calls.last.arguments, {'volume': 0.35});
    await output.setVolume(9);
    expect(output.volume, 1);
    await output.setVolume(-1);
    expect(output.volume, 0);
    final before = calls.length;
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity
    ]) {
      await output.setVolume(invalid);
    }
    expect(calls.length, before);
    await output.setVolume(0.6);
    await output.newStream(44100);
    expect(output.volume, 0.6);
    await output.stop();
    await output.prepare();
    expect(calls.last.arguments, {'volume': 0.6});
    await output.stop();
  });

  test('volume errors retain the last confirmed value and fail prepare safely',
      () async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    await output.setVolume(0.4);
    messenger.setMockMethodCallHandler(player, (call) async {
      calls.add(call);
      if (call.method == 'setRemoteReturnVolume') {
        throw PlatformException(code: 'output_unavailable');
      }
      return null;
    });
    await expectLater(output.setVolume(0.7), throwsA(isA<PlatformException>()));
    expect(output.volume, 0.4);
    await expectLater(output.prepare(), throwsA(isA<PlatformException>()));
    expect(calls.last.method, 'stopRemoteReturn');
  });

  testWidgets(
      'meter samples every fourth packet, smooths and fades without audio',
      (tester) async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    await output.setVolume(0);
    final packet = listenRoomPacket([0.1, -0.75, 0.5, 0.2]);
    final original = Uint8List.fromList(packet);
    for (var i = 0; i < 3; ++i) {
      expect(await output.write(packet), isTrue);
    }
    expect(output.level.value, 0);
    await output.write(packet);
    expect(output.level.value, 0.75,
        reason: 'pre-volume peak includes right channel');
    expect(packet, original, reason: 'meter never modifies PCM');
    final forwarded = calls.where((c) => c.method == 'writeRemoteReturn').last;
    expect(forwarded.arguments, original);
    for (var i = 0; i < 4; ++i) {
      await output.write(listenRoomPacket([0, 0]));
    }
    expect(output.level.value, closeTo(0.6, 0.00001));
    await tester.pump(const Duration(milliseconds: 100));
    expect(output.level.value, closeTo(0.36, 0.00001));
    await tester.pump(const Duration(seconds: 2));
    expect(output.level.value, 0);
    await output.stop();
  });

  testWidgets(
      'meter rejects malformed/nonfinite PCM, clamps peaks and resets streams',
      (tester) async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    for (final packet in [
      Uint8List(64),
      listenRoomPacket([double.nan, 0]),
      listenRoomPacket([0, double.infinity])
    ]) {
      for (var i = 0; i < 4; ++i) {
        await output.write(packet);
      }
      expect(output.level.value, 0);
    }
    for (var i = 0; i < 4; ++i) {
      await output.write(listenRoomPacket([-2, 0]));
    }
    expect(output.level.value, 1);
    await output.newStream(44100);
    expect(output.level.value, 0);
    for (var i = 0; i < 3; ++i) {
      await output.write(listenRoomPacket([1, 0]));
    }
    expect(output.level.value, 0, reason: 'sampling counter resets too');
    await output.write(listenRoomPacket([1, 0]));
    expect(output.level.value, 1);
    await output.stop();
    await tester.pump(const Duration(seconds: 1));
    expect(output.level.value, 0);
  });

  testWidgets(
      'dropped packets and late replies after reset/stop cannot light the meter',
      (tester) async {
    final output = IosLaptopListenOutput();
    await output.prepare();
    messenger.setMockMethodCallHandler(
        audio, (call) async => {'accepted': false});
    for (var i = 0; i < 4; ++i) {
      expect(await output.write(listenRoomPacket([1, 1])), isFalse);
    }
    expect(output.level.value, 0);
    for (final stop in [false, true]) {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(audio, (call) async {
        if (call.method == 'writeRemoteReturn') await gate.future;
        return {'accepted': true};
      });
      final writes =
          List.generate(4, (_) => output.write(listenRoomPacket([1, 1])));
      if (stop) {
        await output.stop();
      } else {
        await output.newStream(48000);
      }
      gate.complete();
      await Future.wait(writes);
      expect(output.level.value, 0);
    }
  });

  test('lock-screen buttons reach the handler while enabled', () async {
    final output = IosLaptopListenOutput();
    final actions = <String>[];
    output.setRemoteCommandHandler(actions.add);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'enable');
    await messenger.handlePlatformMessage(
        IosLaptopListenOutput.nowPlayingChannel,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('command', 'next')),
        (_) {});
    expect(actions, ['next']);
    output.setRemoteCommandHandler(null);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'disable');
  });

  testWidgets('the screen asks for the laptop sign-in first', (tester) async {
    final session = LaptopListenController(output: IosLaptopListenOutput());
    addTearDown(session.dispose);
    await tester
        .pumpWidget(MaterialApp(home: IosLaptopListenScreen(session: session)));
    expect(find.text('Sign in to laptop'), findsOneWidget);
    expect(find.text('Owner account'), findsOneWidget);
  });

  testWidgets('the iPad header offers Listen to laptop', (tester) async {
    final controller = EngineController(engine: MockEngine());
    addTearDown(controller.dispose);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MobileNowPlayingHeader(
                controller: controller,
                backend: EngineBackend.mock,
                status: 'Ready',
                onListenToLaptop: () => ++opened))));
    await tester.tap(find.byKey(const Key('yinwei-listen-to-laptop')));
    expect(opened, 1);
    expect(defaultTargetPlatform, isNot(TargetPlatform.iOS));
  });
}
