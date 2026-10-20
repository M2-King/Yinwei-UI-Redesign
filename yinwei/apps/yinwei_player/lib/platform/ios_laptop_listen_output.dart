import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';

/// The iPad's native output for "Listen to laptop": the same bounded player
/// as the capture route's return audio (listen mode: it holds the audio
/// session and survives route changes and interruptions), plus the lock
/// screen and Control Center through `dev.yinwei/now_playing`.
class IosLaptopListenOutput implements LaptopListenOutput {
  IosLaptopListenOutput(
      {MethodChannel? player, MethodChannel? audio, MethodChannel? nowPlaying})
      : _player =
            player ?? const MethodChannel(ReplayKitAudioProbe.channelName),
        _audio = audio ?? const MethodChannel(audioChannel),
        _nowPlaying = nowPlaying ?? const MethodChannel(nowPlayingChannel) {
    _nowPlaying.setMethodCallHandler((call) async {
      final action = call.arguments;
      if (call.method == 'command' && action is String) _handler?.call(action);
      return null;
    });
  }

  static const nowPlayingChannel = 'dev.yinwei/now_playing';

  /// Audio packets only, handled on a background queue on the iPad: about
  /// 100 a second, they must not wait behind the main thread (the room's
  /// WebView, the UI).
  static const audioChannel = 'dev.yinwei/remote_return_audio';
  final MethodChannel _player, _audio, _nowPlaying;
  void Function(String action)? _handler;
  bool _prepared = false;
  double _volume = 1;

  /// Local listening gain. Kept with the output so reopening the room and
  /// stopping/restarting listening do not reset the slider.
  double get volume => _volume;

  Future<void> setVolume(double value) async {
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 1.0).toDouble();
    if (_prepared) {
      await _player
          .invokeMethod<void>('setRemoteReturnVolume', {'volume': next});
    }
    _volume = next;
  }

  /// Pre-volume peak of the received, processed stereo (not a hardware meter).
  /// Reading samples never changes the packet forwarded to the native player.
  final ValueNotifier<double> level = ValueNotifier<double>(0);
  int _meterGeneration = 0, _meterPackets = 0;
  Timer? _levelDecay;

  void _resetLevel() {
    ++_meterGeneration;
    _meterPackets = 0;
    _levelDecay?.cancel();
    _levelDecay = null;
    level.value = 0;
  }

  void _sampleLevel(Uint8List packet) {
    if (++_meterPackets % 4 != 0 || YnwPacketHeader.parse(packet) == null) {
      return;
    }
    // YNW1: 56-byte header, interleaved little-endian stereo Float32 PCM.
    // At most 512 frames (1024 scalar samples), every fourth accepted packet.
    final data = ByteData.sublistView(packet);
    var peak = 0.0;
    for (var offset = 56; offset < packet.length; offset += 4) {
      final sample = data.getFloat32(offset, Endian.little);
      if (!sample.isFinite) return;
      peak = math.max(peak, sample.abs());
    }
    level.value = math.max(peak.clamp(0.0, 1.0), level.value * 0.8);
    _levelDecay?.cancel();
    _decayLevel();
  }

  // A lost stream or paused source must not leave the last peak frozen.
  void _decayLevel() {
    _levelDecay = level.value == 0
        ? null
        : Timer(const Duration(milliseconds: 100), () {
            final next = level.value * 0.6;
            level.value = next < 0.001 ? 0 : next;
            _decayLevel();
          });
  }

  @override
  Future<void> prepare() async {
    _prepared = false;
    _resetLevel();
    await _player.invokeMethod<void>('prepareRemoteReturn', {'listen': true});
    try {
      await _player
          .invokeMethod<void>('setRemoteReturnVolume', {'volume': _volume});
      _prepared = true;
    } catch (_) {
      await _player.invokeMethod<void>('stopRemoteReturn');
      rethrow;
    }
  }

  @override
  Future<void> newStream(int sampleRate) {
    _resetLevel();
    return _player.invokeMethod<void>(
        'resetRemoteReturn', {'newStream': true, 'sampleRate': sampleRate});
  }

  @override
  Future<bool> write(Uint8List packet) async {
    final generation = _meterGeneration;
    try {
      final result = await _audio.invokeMapMethod<String, dynamic>(
          'writeRemoteReturn', packet);
      final accepted = result?['accepted'] == true;
      if (accepted && _prepared && generation == _meterGeneration) {
        _sampleLevel(packet);
      }
      return accepted;
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
  Future<void> stop() {
    _prepared = false;
    _resetLevel();
    return _player.invokeMethod<void>('stopRemoteReturn');
  }

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
