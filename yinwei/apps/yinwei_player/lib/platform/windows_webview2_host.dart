import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// WebView2 embedder for the shared Three.js workspace. Windows only.
class WindowsWebView2Host implements SpatialWorkspaceHost {
  WebviewController? _controller;
  Widget? _view;
  final _subs = <StreamSubscription>[];

  @override
  bool get usesWebView => true;

  @override
  Widget? get view => _view;

  @override
  Future<void> boot({
    required String html,
    required String poseBridgeScript,
    required void Function(dynamic message) onMessage,
    required VoidCallback onReady,
    required void Function(Object error) onLoadError,
  }) async {
    if (_controller != null) return;
    final version = await WebviewController.getWebViewVersion();
    debugPrint('[SpatialWorkspace] WebView2 runtime=$version');
    if (version == null) {
      throw StateError('WebView2 runtime missing');
    }
    final controller = WebviewController();
    await controller.initialize();
    _subs.add(controller.webMessage.listen(onMessage));
    _subs.add(
      controller.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) {
          onReady();
        }
      }),
    );
    _subs.add(
      controller.onLoadError.listen((status) => onLoadError(status)),
    );
    await controller.setBackgroundColor(YinweiColors.background);
    await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    await controller.addScriptToExecuteOnDocumentCreated(poseBridgeScript);
    await controller.loadStringContent(html);
    _controller = controller;
    _view = ColoredBox(
      color: YinweiColors.background,
      child: Webview(controller),
    );
  }

  @override
  Future<void> setSuspended(bool suspended) async {
    final web = _controller;
    if (web == null) return;
    // Cap compositor work if this surface is hidden. Do not TrySuspend;
    // that native Stop+Start path aborted flutter_windows.dll.
    await web.setFpsLimit(suspended ? 1 : 0);
  }

  @override
  Future<dynamic> executeScript(String script) {
    final web = _controller;
    if (web == null) return Future<dynamic>.value();
    return web.executeScript(script);
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final web = _controller;
    _controller = null;
    _view = null;
    if (web != null) {
      await web.dispose();
    }
  }
}
