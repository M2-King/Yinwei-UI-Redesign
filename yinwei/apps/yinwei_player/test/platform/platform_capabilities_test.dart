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
  });

  test('detect follows the Windows product profile on this host', () {
    final caps = PlatformCapabilities.detect();
    expect(caps.liveTransfer, Platform.isWindows);
    expect(caps.floatingIsland, Platform.isWindows);
    expect(caps.threeJsWebView, Platform.isWindows);
    if (Platform.isWindows) {
      expect(caps, PlatformCapabilities.windows);
    } else {
      expect(caps, PlatformCapabilities.none);
    }
  });
}
