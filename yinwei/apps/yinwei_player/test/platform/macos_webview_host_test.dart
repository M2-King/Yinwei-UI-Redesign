import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/macos_webview_host.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/platform/three_js_host_bind.dart';
import 'package:yinwei_player/platform/windows_webview2_host.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

class _Driver implements MacOSWebViewDriver {
  final initialized = Completer<void>();
  ValueChanged<String>? message;
  ValueChanged<Object>? error;
  String? document;
  final scripts = <String>[];
  int disposals = 0;
  @override
  Widget get view => const SizedBox();
  @override
  Future<void> initialize(
      {required ValueChanged<String> onMessage,
      required ValueChanged<Object> onError}) async {
    message = onMessage;
    error = onError;
    await initialized.future;
  }

  @override
  Future<void> load(String html) async {
    document = html;
  }

  @override
  Future<dynamic> execute(String script) async {
    scripts.add(script);
    return null;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('host selection preserves Windows and chooses WKWebView on macOS', () {
    expect(createThreeJsWorkspaceHost(operatingSystem: 'windows'),
        isA<WindowsWebView2Host>());
    expect(createThreeJsWorkspaceHost(operatingSystem: 'macos'),
        isA<MacOSWebViewHost>());
    expect(createThreeJsWorkspaceHost(operatingSystem: 'linux'),
        isA<FallbackWorkspaceHost>());
  });
  test('bridge precedes scene startup; ready, intent and suspension round-trip',
      () async {
    final driver = _Driver()..initialized.complete();
    final host = MacOSWebViewHost(driverFactory: () => driver);
    final messages = <dynamic>[];
    final errors = <Object>[];
    var ready = 0;
    await host.setSuspended(true);
    await host.boot(
        html: '<html><head></head><body>scene</body></html>',
        poseBridgeScript: kYinweiPoseBridgeScript,
        onMessage: messages.add,
        onReady: () => ready++,
        onLoadError: errors.add);
    expect(driver.document, contains('window.YinweiNative.postMessage'));
    expect(driver.document!.indexOf('window.YinweiPose'),
        lessThan(driver.document!.indexOf('scene')));
    expect(host.view, isNotNull);
    expect(driver.scripts, isEmpty);
    driver.message!('{"type":"ready"}');
    await Future<void>.delayed(Duration.zero);
    driver.message!('{"type":"ready"}');
    driver.message!('{"type":"selectObject","objectId":"listener-0"}');
    expect(ready, 1);
    expect(messages.last, contains('listener-0'));
    expect(driver.scripts, contains(contains('setHostSuspended(true)')));
    await host.setSuspended(false);
    expect(driver.scripts.last, contains('setHostSuspended(false)'));
    await host.dispose();
    driver.message!('{"type":"ready"}');
    expect(ready, 1);
    expect(driver.disposals, 1);
    expect(errors, isEmpty);
    expect(host.view, isNull);
  });
  test('late initialization cannot resurrect a disposed platform view',
      () async {
    final driver = _Driver();
    final host = MacOSWebViewHost(driverFactory: () => driver);
    var callbacks = 0;
    final boot = host.boot(
        html: '<head></head>',
        poseBridgeScript: '',
        onMessage: (_) => callbacks++,
        onReady: () => callbacks++,
        onLoadError: (_) => callbacks++);
    final disposal = host.dispose();
    driver.initialized.complete();
    await boot;
    await disposal;
    driver.message!('{"type":"ready"}');
    expect(driver.document, isNull);
    expect(driver.disposals, 1);
    expect(callbacks, 0);
    await host.dispose();
    expect(driver.disposals, 1);
  });
  test('scene failures are reported; malformed messages do not write state',
      () async {
    final driver = _Driver()..initialized.complete();
    final host = MacOSWebViewHost(driverFactory: () => driver);
    final errors = <Object>[];
    final messages = <dynamic>[];
    await host.boot(
        html: '<head></head>',
        poseBridgeScript: '',
        onMessage: messages.add,
        onReady: () {},
        onLoadError: errors.add);
    driver.message!('bad json');
    driver.message!('{"type":"hostError","message":"WebGL failed"}');
    expect(messages, isEmpty);
    expect(errors.single.toString(), contains('WebGL failed'));
    await host.dispose();
    driver.error!(StateError('late failure'));
    expect(errors.length, 1);
  });
}
