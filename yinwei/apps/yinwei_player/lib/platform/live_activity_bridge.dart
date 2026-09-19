import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';

/// Presentation-only Live Activity / Dynamic Island bridge.
///
/// Never writes SceneStore, EngineApi, or DSP. Native ActivityKit is a sink.
abstract class LiveActivityBridge {
  const LiveActivityBridge();

  static const channelName = 'dev.yinwei/live_activity';

  bool get available;

  Future<void> start(YinweiLivePresentation presentation);

  Future<void> update(YinweiLivePresentation presentation);

  Future<void> end();

  factory LiveActivityBridge.create({
    required PlatformCapabilities capabilities,
    MethodChannel? channel,
    bool? isIOS,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    if (!ios || !capabilities.liveActivity) {
      return const UnavailableLiveActivityBridge();
    }
    return MethodChannelLiveActivityBridge(channel: channel);
  }
}

class UnavailableLiveActivityBridge implements LiveActivityBridge {
  const UnavailableLiveActivityBridge();

  @override
  bool get available => false;

  @override
  Future<void> start(YinweiLivePresentation presentation) async {}

  @override
  Future<void> update(YinweiLivePresentation presentation) async {}

  @override
  Future<void> end() async {}
}

class MethodChannelLiveActivityBridge implements LiveActivityBridge {
  MethodChannelLiveActivityBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(LiveActivityBridge.channelName);

  final MethodChannel _channel;

  @override
  bool get available => true;

  @override
  Future<void> start(YinweiLivePresentation presentation) {
    return _channel.invokeMethod<void>('start', presentation.toChannelPayload());
  }

  @override
  Future<void> update(YinweiLivePresentation presentation) {
    return _channel.invokeMethod<void>(
      'update',
      presentation.toChannelPayload(),
    );
  }

  @override
  Future<void> end() {
    return _channel.invokeMethod<void>('end');
  }
}
