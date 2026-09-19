import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/platform/three_js_host_stub.dart'
    if (dart.library.io) 'package:yinwei_player/platform/three_js_host_bind.dart'
    as three_js_host;

/// Host for the shared Three.js workspace. One scene.js, many embedders.
abstract class SpatialWorkspaceHost {
  bool get usesWebView;
  Widget? get view;

  Future<void> boot({
    required String html,
    required String poseBridgeScript,
    required void Function(dynamic message) onMessage,
    required VoidCallback onReady,
    required void Function(Object error) onLoadError,
  });

  Future<void> setSuspended(bool suspended);

  Future<dynamic> executeScript(String script);

  Future<void> dispose();
}

/// Tests / missing runtime / hosts without a Three.js WebView.
class FallbackWorkspaceHost implements SpatialWorkspaceHost {
  @override
  bool get usesWebView => false;

  @override
  Widget? get view => null;

  @override
  Future<void> boot({
    required String html,
    required String poseBridgeScript,
    required void Function(dynamic message) onMessage,
    required VoidCallback onReady,
    required void Function(Object error) onLoadError,
  }) async {}

  @override
  Future<void> setSuspended(bool suspended) async {}

  @override
  Future<dynamic> executeScript(String script) async => null;

  @override
  Future<void> dispose() async {}
}

SpatialWorkspaceHost createSpatialWorkspaceHost({
  required PlatformCapabilities capabilities,
  bool forceFallback = false,
}) {
  if (forceFallback || kIsWeb || !capabilities.threeJsWebView) {
    return FallbackWorkspaceHost();
  }
  return three_js_host.createThreeJsWorkspaceHost();
}
