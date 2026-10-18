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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const player = MethodChannel(ReplayKitAudioProbe.channelName);
  const nowPlaying = MethodChannel(IosLaptopListenOutput.nowPlayingChannel);
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    for (final channel in [player, nowPlaying]) {
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
    messenger.setMockMethodCallHandler(nowPlaying, null);
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
      'resetRemoteReturn',
      'writeRemoteReturn',
      'getRemoteReturnStatus',
      'update',
      'clear',
      'stopRemoteReturn',
    ]);
    expect(calls[0].arguments, {'listen': true});
    expect(calls[1].arguments, {'newStream': true, 'sampleRate': 44100});
    expect(calls[4].arguments,
        {'title': 'Song', 'artist': 'Music', 'playing': true});

    // Swift source agrees on these names.
    final swift =
        File('ios/Runner/YinweiReplayKitProbe.swift').readAsStringSync();
    for (final name in [
      '"listen"',
      '"newStream"',
      '"sampleRate"',
      '"interrupted"',
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
    await tester.pumpWidget(MaterialApp(
        home: IosLaptopListenScreen(session: session)));
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
