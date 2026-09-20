import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  test('Windows product profile enables desktop and live adapters', () {
    const caps = PlatformCapabilities.windows;
    expect(caps.desktopWindow, isTrue);
    expect(caps.nativeWindowChrome, isTrue);
    expect(caps.floatingIsland, isTrue);
    expect(caps.systemMedia, isTrue);
    expect(caps.liveTransfer, isTrue);
    expect(caps.desktopDrop, isTrue);
    expect(caps.threeJsWebView, isTrue);
    expect(caps.filePlayback, isTrue);
    expect(caps.pointSpatial, isTrue);
    expect(caps.array, isTrue);
    expect(caps.liveActivity, isFalse);
    expect(caps.appClip, isFalse);
    expect(caps.mobileFileImport, isFalse);
    expect(caps.audioSession, isFalse);
    expect(caps.androidPlaybackCapture, isFalse);
  });

  test('non-Windows defaults disable Windows-only product surfaces', () {
    const caps = PlatformCapabilities.none;
    expect(caps.desktopWindow, isFalse);
    expect(caps.nativeWindowChrome, isFalse);
    expect(caps.floatingIsland, isFalse);
    expect(caps.systemMedia, isFalse);
    expect(caps.liveTransfer, isFalse);
    expect(caps.desktopDrop, isFalse);
    expect(caps.threeJsWebView, isFalse);
    expect(caps.filePlayback, isFalse);
    expect(caps.pointSpatial, isFalse);
    expect(caps.array, isFalse);
    expect(caps.liveActivity, isFalse);
    expect(caps.appClip, isFalse);
    expect(caps.mobileFileImport, isFalse);
    expect(caps.audioSession, isFalse);
    expect(caps.androidPlaybackCapture, isFalse);
  });

  test('iOS product profile keeps Point audio and hides Windows chrome', () {
    const caps = PlatformCapabilities.ios;
    expect(caps.desktopWindow, isFalse);
    expect(caps.nativeWindowChrome, isFalse);
    expect(caps.floatingIsland, isFalse);
    expect(caps.systemMedia, isFalse);
    expect(caps.liveTransfer, isFalse);
    expect(caps.desktopDrop, isFalse);
    expect(caps.threeJsWebView, isFalse);
    expect(caps.filePlayback, isTrue);
    expect(caps.pointSpatial, isTrue);
    expect(caps.array, isTrue);
    expect(caps.liveActivity, isTrue);
    expect(caps.appClip, isTrue);
    expect(caps.mobileFileImport, isTrue);
    expect(caps.audioSession, isTrue);
    expect(caps.androidPlaybackCapture, isFalse);
  });

  test('Android product profile keeps Point audio and hides Windows chrome', () {
    const caps = PlatformCapabilities.android;
    expect(caps.desktopWindow, isFalse);
    expect(caps.nativeWindowChrome, isFalse);
    expect(caps.floatingIsland, isFalse);
    expect(caps.systemMedia, isFalse);
    expect(caps.liveTransfer, isFalse);
    expect(caps.desktopDrop, isFalse);
    expect(caps.threeJsWebView, isFalse);
    expect(caps.filePlayback, isTrue);
    expect(caps.pointSpatial, isTrue);
    expect(caps.array, isTrue);
    expect(caps.liveActivity, isFalse);
    expect(caps.appClip, isFalse);
    expect(caps.mobileFileImport, isTrue);
    expect(caps.audioSession, isFalse);
    expect(caps.androidPlaybackCapture, isTrue);
    expect(caps.usesMobilePlayer, isTrue);
  });

  test('detect follows the Windows product profile on this host', () {
    final caps = PlatformCapabilities.detect();
    expect(caps.liveTransfer, Platform.isWindows);
    expect(caps.floatingIsland, Platform.isWindows);
    expect(caps.threeJsWebView, Platform.isWindows);
    expect(caps.androidPlaybackCapture, Platform.isAndroid);
    if (Platform.isWindows) {
      expect(caps, PlatformCapabilities.windows);
    } else if (Platform.isIOS) {
      expect(caps, PlatformCapabilities.ios);
    } else if (Platform.isAndroid) {
      expect(caps, PlatformCapabilities.android);
    } else {
      expect(caps, PlatformCapabilities.none);
    }
  });
}
