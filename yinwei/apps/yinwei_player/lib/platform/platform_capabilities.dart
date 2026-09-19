import 'dart:io';

import 'package:flutter/foundation.dart';

/// Product capability layer — not plugin/feature detection and not audio state.
///
/// Windows remains the shipping desktop profile. iOS is the first Apple proof
/// profile: Point spatial + file playback, no Win32 Island/SMTC/WASAPI.
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
    this.filePlayback = false,
    this.pointSpatial = false,
    this.array = false,
    this.liveActivity = false,
    this.appClip = false,
    this.mobileFileImport = false,
    this.audioSession = false,
  });

  final bool desktopWindow;
  final bool nativeWindowChrome;
  final bool floatingIsland;
  final bool systemMedia;
  final bool liveTransfer;
  final bool desktopDrop;
  final bool threeJsWebView;
  final bool filePlayback;
  final bool pointSpatial;
  final bool array;
  final bool liveActivity;
  final bool appClip;
  final bool mobileFileImport;
  final bool audioSession;

  static const windows = PlatformCapabilities(
    desktopWindow: true,
    nativeWindowChrome: true,
    floatingIsland: true,
    systemMedia: true,
    liveTransfer: true,
    desktopDrop: true,
    threeJsWebView: true,
    filePlayback: true,
    pointSpatial: true,
    array: true,
  );

  static const ios = PlatformCapabilities(
    desktopWindow: false,
    nativeWindowChrome: false,
    floatingIsland: false,
    systemMedia: false,
    liveTransfer: false,
    desktopDrop: false,
    threeJsWebView: false,
    filePlayback: true,
    pointSpatial: true,
    array: true,
    liveActivity: true,
    appClip: true,
    mobileFileImport: true,
    audioSession: true,
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
    if (Platform.isIOS) return ios;
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
        threeJsWebView == other.threeJsWebView &&
        filePlayback == other.filePlayback &&
        pointSpatial == other.pointSpatial &&
        array == other.array &&
        liveActivity == other.liveActivity &&
        appClip == other.appClip &&
        mobileFileImport == other.mobileFileImport &&
        audioSession == other.audioSession;
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
        filePlayback,
        pointSpatial,
        array,
        liveActivity,
        appClip,
        mobileFileImport,
        audioSession,
      );
}
