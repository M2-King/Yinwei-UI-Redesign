import 'dart:async';

import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';

/// The iPad's native output for "Listen to laptop": the same bounded player
/// as the capture route's return audio (listen mode: it holds the audio
/// session and survives route changes and interruptions), plus the lock
/// screen and Control Center through `dev.yinwei/now_playing`.
class IosLaptopListenOutput implements LaptopListenOutput {
  IosLaptopListenOutput({MethodChannel? player, MethodChannel? nowPlaying})
      : _player =
            player ?? const MethodChannel(ReplayKitAudioProbe.channelName),
        _nowPlaying = nowPlaying ?? const MethodChannel(nowPlayingChannel) {
    _nowPlaying.setMethodCallHandler((call) async {
      final action = call.arguments;
      if (call.method == 'command' && action is String) _handler?.call(action);
      return null;
    });
  }

  static const nowPlayingChannel = 'dev.yinwei/now_playing';
  final MethodChannel _player, _nowPlaying;
  void Function(String action)? _handler;

  @override
  Future<void> prepare() =>
      _player.invokeMethod<void>('prepareRemoteReturn', {'listen': true});

  @override
  Future<void> newStream(int sampleRate) => _player.invokeMethod<void>(
      'resetRemoteReturn', {'newStream': true, 'sampleRate': sampleRate});

  @override
  Future<bool> write(Uint8List packet) async {
    try {
      final result = await _player.invokeMapMethod<String, dynamic>(
          'writeRemoteReturn', packet);
      return result?['accepted'] == true;
    } on PlatformException {
      // Interrupted output: the status poll decides whether to stop.
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> status() async =>
      await _player.invokeMapMethod<String, dynamic>('getRemoteReturnStatus') ??
      const {};

  @override
  Future<void> stop() => _player.invokeMethod<void>('stopRemoteReturn');

  @override
  Future<void> showNowPlaying(
          {required String title,
          required String artist,
          required bool playing}) =>
      _nowPlaying.invokeMethod<void>(
          'update', {'title': title, 'artist': artist, 'playing': playing});

  @override
  Future<void> hideNowPlaying() => _nowPlaying.invokeMethod<void>('clear');

  @override
  void setRemoteCommandHandler(void Function(String action)? handler) {
    _handler = handler;
    unawaited(_nowPlaying
        .invokeMethod<void>(handler == null ? 'disable' : 'enable')
        .catchError((Object _) {}));
  }
}
