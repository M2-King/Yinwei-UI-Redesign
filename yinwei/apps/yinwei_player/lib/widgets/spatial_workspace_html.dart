import 'package:flutter/services.dart';

/// Bundles the local Three.js workspace into one HTML document for WebView2.
class SpatialWorkspaceHtml {
  static const _shellAsset = 'assets/spatial_workspace/index.html';
  static const _threeAsset = 'assets/spatial_workspace/vendor/three.min.js';
  static const _sceneAsset = 'assets/spatial_workspace/scene.js';

  static Future<String> load() async {
    final shell = await rootBundle.loadString(_shellAsset);
    final three = _safeInline(await rootBundle.loadString(_threeAsset));
    final scene = _safeInline(await rootBundle.loadString(_sceneAsset));
    return shell
        .replaceFirst(
          '<script src="vendor/three.min.js"></script>',
          '<script>$three</script>',
        )
        .replaceFirst(
          '<script src="scene.js"></script>',
          '<script>$scene</script>',
        );
  }

  static String _safeInline(String js) => js.replaceAll('</', r'<\/');
}
