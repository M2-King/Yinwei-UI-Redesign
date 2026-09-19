import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/platform/windows_webview2_host.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Three.js capability off selects the fallback host', () {
    final host = createSpatialWorkspaceHost(
      capabilities: PlatformCapabilities.none,
    );
    expect(host, isA<FallbackWorkspaceHost>());
    expect(host.usesWebView, isFalse);
  });

  test('Windows Three.js capability selects the WebView2 host', () {
    final host = createSpatialWorkspaceHost(
      capabilities: PlatformCapabilities.windows,
    );
    expect(host, isA<WindowsWebView2Host>());
    expect(host.usesWebView, isTrue);
  });

  testWidgets('fallback host renders OrbitVisualizer without Windows WebView',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: const Scaffold(
          body: SizedBox.square(
            dimension: 420,
            child: SpatialWorkspace(
              playhead: 0.2,
              azimuthDeg: 0,
              elevationDeg: 0,
              distanceM: 1.5,
              envelopment: 0.5,
              capabilities: PlatformCapabilities.none,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(OrbitVisualizer), findsOneWidget);
  });
}
