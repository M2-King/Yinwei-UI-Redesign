import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

/// Presents a completed, app-owned processed file to the platform.
///
/// Export rendering remains in spatial_core. This boundary only opens the
/// native iOS share/save sheet after the WAV has been written successfully.
abstract class MediaExportDelivery {
  const MediaExportDelivery();

  bool get available;

  Future<bool> shareFile(String path);

  factory MediaExportDelivery.create({
    required PlatformCapabilities capabilities,
    MethodChannel? channel,
    bool? isIOS,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    if (!ios || !capabilities.mobileFileImport) {
      return const UnavailableMediaExportDelivery();
    }
    return IosMediaExportDelivery(channel: channel);
  }
}

class UnavailableMediaExportDelivery implements MediaExportDelivery {
  const UnavailableMediaExportDelivery();

  @override
  bool get available => false;

  @override
  Future<bool> shareFile(String path) async => false;
}

class IosMediaExportDelivery implements MediaExportDelivery {
  IosMediaExportDelivery({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'dev.yinwei/developer_diagnostics';

  final MethodChannel _channel;

  @override
  bool get available => true;

  @override
  Future<bool> shareFile(String path) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'shareFile',
      {'path': path},
    );
    return result?['ok'] == true && result?['shared'] == true;
  }
}
