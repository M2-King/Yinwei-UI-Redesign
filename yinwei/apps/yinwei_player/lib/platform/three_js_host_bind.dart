import 'dart:io';

import 'package:yinwei_player/platform/macos_webview_host.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/platform/windows_webview2_host.dart';

SpatialWorkspaceHost createThreeJsWorkspaceHost({String? operatingSystem}) {
  switch (operatingSystem ?? Platform.operatingSystem) {
    case 'windows':
      return WindowsWebView2Host();
    case 'macos':
      return MacOSWebViewHost();
    default:
      return FallbackWorkspaceHost();
  }
}
