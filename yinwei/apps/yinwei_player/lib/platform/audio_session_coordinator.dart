import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

/// Future AVAudioSession seam. Not WASAPI, SMTC, or DSP.
abstract class AudioSessionCoordinator {
  const AudioSessionCoordinator();

  static const channelName = 'dev.yinwei/audio_session';

  bool get available;

  Future<void> activateForPlayback();

  Future<void> deactivate();

  factory AudioSessionCoordinator.create({
    required PlatformCapabilities capabilities,
    MethodChannel? channel,
    bool? isIOS,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    if (!ios || !capabilities.audioSession) {
      return const UnavailableAudioSessionCoordinator();
    }
    return MethodChannelAudioSessionCoordinator(channel: channel);
  }
}

class UnavailableAudioSessionCoordinator implements AudioSessionCoordinator {
  const UnavailableAudioSessionCoordinator();

  @override
  bool get available => false;

  @override
  Future<void> activateForPlayback() async {}

  @override
  Future<void> deactivate() async {}
}

class MethodChannelAudioSessionCoordinator implements AudioSessionCoordinator {
  MethodChannelAudioSessionCoordinator({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel(AudioSessionCoordinator.channelName);

  final MethodChannel _channel;

  @override
  bool get available => true;

  @override
  Future<void> activateForPlayback() {
    return _channel.invokeMethod<void>('activate');
  }

  @override
  Future<void> deactivate() {
    return _channel.invokeMethod<void>('deactivate');
  }
}
