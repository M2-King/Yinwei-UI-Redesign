import 'dart:convert';
import 'dart:developer' as developer;

/// Debug builds only. Enables local VM-service stress tests of the same UI
/// callbacks and returns authoritative snapshots; never constructs audio state.
void registerIslandRuntimeProbe(Future<Map<String, Object?>> Function(Map<String, String>) handle) {
  assert(() {
    developer.registerExtension('ext.yinwei.island', (_, parameters) async {
      try { return developer.ServiceExtensionResponse.result(jsonEncode(await handle(parameters))); }
      catch (e) { return developer.ServiceExtensionResponse.error(-32000, '$e'); }
    });
    return true;
  }());
}
