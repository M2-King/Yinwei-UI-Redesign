import 'dart:convert';

import 'package:flutter/services.dart';

/// Builds the offline Listen Room page (`assets/listen_room/`) as one document
/// for the WebView, the way `SpatialWorkspaceHtml` does for the workspace:
/// every script, the stylesheet, its fonts and its picture are inlined in the
/// order `index.html` lists them. Nothing is loaded from the network, and the
/// review stand-in (`dev/`) is never included.
class ListenRoomHtml {
  static const folder = 'assets/listen_room/';

  static final _script = RegExp(r'<script src="([^"]+)"></script>');
  static final _cssUrl = RegExp(r'url\("((?!data:)[^"]+)"\)');
  static const _stylesheet = '<link rel="stylesheet" href="ui.css">';
  static const _mime = {
    'woff2': 'font/woff2',
    'jpg': 'image/jpeg',
    'png': 'image/png',
  };

  static Future<String> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    var page = await assets.loadString('${folder}index.html');
    if (!page.contains(_stylesheet) || page.contains('dev/')) {
      throw StateError('Listen Room index.html is not the expected page');
    }

    // Fonts and the still picture become data URIs inside the stylesheet.
    var css = await assets.loadString('${folder}ui.css');
    final files = <String, String>{};
    for (final name in _cssUrl.allMatches(css).map((m) => m[1]!).toSet()) {
      final type = _mime[name.split('.').last];
      if (type == null) throw StateError('Unknown file type in ui.css: $name');
      final bytes = await assets.load('$folder$name');
      files[name] = 'data:$type;base64,'
          '${base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes))}';
    }
    css = css.replaceAllMapped(_cssUrl, (m) => 'url("${files[m[1]]}")');
    page = page.replaceFirst(_stylesheet, '<style>\n$css</style>');

    // Scripts, in order.
    final scripts = <String, String>{};
    for (final name in _script.allMatches(page).map((m) => m[1]!).toSet()) {
      scripts[name] = _safeInline(await assets.loadString('$folder$name'));
    }
    page = page.replaceAllMapped(
        _script, (m) => '<script>\n${scripts[m[1]]}\n</script>');

    if (RegExp(r'<(script|link)[^>]+(src|href)=').hasMatch(page)) {
      throw StateError('Listen Room page still references a file');
    }
    return page;
  }

  // A "</" inside a script would end the inline <script> element early.
  static String _safeInline(String js) => js.replaceAll('</', r'<\/');
}
