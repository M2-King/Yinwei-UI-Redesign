import 'dart:io';

import 'package:flutter/foundation.dart';

/// Product capability layer — not plugin/feature detection and not audio state.
///
/// Windows is the current shipping profile. Future hosts start from [none]
/// until a platform-native adapter is deliberately designed.
@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.desktopWindow,
    required this.nativeWindowChrome,
    required this.floatingIsland,
    required this.systemMedia,
    required this.liveTransfer,
    required this.desktopDrop,
    required this.threeJsWebView,
  });

  final bool desktopWindow;
  final bool nativeWindowChrome;
  final bool floatingIsland;
  final bool systemMedia;
  final bool liveTransfer;
  final bool desktopDrop;
  final bool threeJsWebView;

  static const windows = PlatformCapabilities(
    desktopWindow: true,
    nativeWindowChrome: true,
    floatingIsland: true,
    systemMedia: true,
    liveTransfer: true,
    desktopDrop: true,
    threeJsWebView: true,
  );

  static const none = PlatformCapabilities(
    desktopWindow: false,
    nativeWindowChrome: false,
    floatingIsland: false,
    systemMedia: false,
    liveTransfer: false,
    desktopDrop: false,
    threeJsWebView: false,
  );

  static PlatformCapabilities detect() {
    if (kIsWeb) return none;
    if (Platform.isWindows) return windows;
    return none;
  }

  @override
  bool operator ==(Object other) {
    return other is PlatformCapabilities &&
        desktopWindow == other.desktopWindow &&
        nativeWindowChrome == other.nativeWindowChrome &&
        floatingIsland == other.floatingIsland &&
        systemMedia == other.systemMedia &&
        liveTransfer == other.liveTransfer &&
        desktopDrop == other.desktopDrop &&
        threeJsWebView == other.threeJsWebView;
  }

  @override
  int get hashCode => Object.hash(
        desktopWindow,
        nativeWindowChrome,
        floatingIsland,
        systemMedia,
        liveTransfer,
        desktopDrop,
        threeJsWebView,
      );
}
