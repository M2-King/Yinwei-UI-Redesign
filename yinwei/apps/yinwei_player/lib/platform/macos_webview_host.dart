import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Native WebView boundary, injectable for lifecycle and protocol tests.
abstract class MacOSWebViewDriver {
  Widget get view;
  Future<void> initialize({
    required ValueChanged<String> onMessage,
    required ValueChanged<Object> onError,
  });
  Future<void> load(String html);
  Future<dynamic> execute(String script);
  Future<void> dispose();
}

class WKWebViewDriver implements MacOSWebViewDriver {
  WebViewController? _controller;

  @override
  Widget get view => WebViewWidget(controller: _controller!);

  @override
  Future<void> initialize({
    required ValueChanged<String> onMessage,
    required ValueChanged<Object> onError,
  }) async {
    final controller = WebViewController();
    _controller = controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(YinweiColors.background);
    await controller.addJavaScriptChannel('YinweiNative',
        onMessageReceived: (message) => onMessage(message.message));
    await controller.setOnConsoleMessage((message) {
      debugPrint('[SpatialWorkspace macOS] ${message.level.name}: '
          '${message.message}');
    });
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) => request.url == 'about:blank'
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
      onWebResourceError: (error) {
        if (error.isForMainFrame != false) {
          onError(StateError('WKWebView: ${error.description}'));
        }
      },
    ));
  }

  @override
  Future<void> load(String html) => _controller!.loadHtmlString(html);

  @override
  Future<dynamic> execute(String script) async {
    final controller = _controller;
    if (controller == null) return null;
    // WKWebView rejects undefined JS return values. Normalize both void state
    // writes and diagnostic objects through JSON at the transport boundary.
    final result = await controller.runJavaScriptReturningResult(
      'JSON.stringify((function(){var value=(0,eval)(${jsonEncode(script)});'
      'return value===undefined?null:value;})())',
    );
    return result is String ? jsonDecode(result) : result;
  }

  @override
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    await controller.removeJavaScriptChannel('YinweiNative');
    // Replacing the document tears down WebGL resources and pending callbacks.
    await controller.loadHtmlString('<html><body></body></html>');
    // WebViewWidget owns the platform view. Removing it releases the native
    // view; webview_flutter exposes no controller dispose API.
  }
}

/// WKWebView host for the existing offline scene and SceneBridge protocol.
class MacOSWebViewHost implements SpatialWorkspaceHost {
  MacOSWebViewHost({MacOSWebViewDriver Function()? driverFactory})
      : _driverFactory = driverFactory ?? WKWebViewDriver.new;

  final MacOSWebViewDriver Function() _driverFactory;
  MacOSWebViewDriver? _driver;
  Widget? _view;
  Future<void>? _boot;
  Timer? _readyTimeout;
  bool _disposed = false;
  bool _ready = false;
  bool _requestedSuspended = false;
  bool _appHidden = false;

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
  }) {
    if (_disposed) return Future.error(StateError('macOS host disposed'));
    return _boot ??= _initialize(
      html,
      poseBridgeScript,
      onMessage,
      onReady,
      onLoadError,
    );
  }

  Future<void> _initialize(
    String html,
    String bridge,
    void Function(dynamic) onMessage,
    VoidCallback onReady,
    ValueChanged<Object> onError,
  ) async {
    final driver = _driverFactory();
    _driver = driver;
    bool current() => !_disposed && identical(driver, _driver);
    void fail(Object error) {
      if (current()) onError(error);
    }

    await driver.initialize(
        onError: fail,
        onMessage: (raw) {
          if (!current()) return;
          dynamic message;
          try {
            message = jsonDecode(raw);
          } catch (_) {
            return;
          }
          if (message is! Map) return;
          if (message['type'] == 'hostError') {
            fail(StateError('Three.js: ${message['message']}'));
            return;
          }
          if (message['type'] == 'ready' && !_ready) {
            _ready = true;
            _readyTimeout?.cancel();
            onMessage(raw);
            onReady();
            unawaited(setSuspended(_requestedSuspended).catchError(fail));
            return;
          }
          onMessage(raw);
        });
    if (!current()) return;
    if (!html.contains('</head>')) {
      throw StateError('Workspace HTML is missing its head boundary');
    }
    _view = _MacOSViewport(
      child: driver.view,
      onHidden: (hidden) {
        _appHidden = hidden;
        unawaited(setSuspended(_requestedSuspended).catchError(fail));
      },
    );
    _readyTimeout = Timer(const Duration(seconds: 20), () {
      if (!_ready) fail(StateError('Three.js readiness timed out'));
    });
    // Channels exist at document start. Install the shared adapter before
    // Three.js executes; no remote server or copied scene implementation.
    final document = html.replaceFirst(
        '</head>', '<script>$bridge\n$_errorBridge</script></head>');
    await driver.load(document);
  }

  @override
  Future<void> setSuspended(bool suspended) async {
    _requestedSuspended = suspended;
    if (_disposed || !_ready) return;
    await _driver?.execute('window.YinweiWorkspace&&'
        'YinweiWorkspace.setHostSuspended(${suspended || _appHidden})');
  }

  @override
  Future<dynamic> executeScript(String script) async {
    if (_disposed || !_ready) return null;
    return _driver?.execute(script);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _readyTimeout?.cancel();
    final driver = _driver;
    _driver = null;
    _view = null;
    await _boot?.catchError((Object _) {});
    await driver?.dispose();
  }
}

const _errorBridge = '''
(function () {
  function report(message) {
    if (window.YinweiNative) window.YinweiNative.postMessage(JSON.stringify({
      type: 'hostError', message: String(message)
    }));
  }
  window.addEventListener('error', function(e) { report(e.message || e.error); });
  window.addEventListener('unhandledrejection', function(e) { report(e.reason); });
})();
''';

class _MacOSViewport extends StatefulWidget {
  const _MacOSViewport({required this.child, required this.onHidden});
  final Widget child;
  final ValueChanged<bool> onHidden;
  @override
  State<_MacOSViewport> createState() => _MacOSViewportState();
}

class _MacOSViewportState extends State<_MacOSViewport>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.onHidden(state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
