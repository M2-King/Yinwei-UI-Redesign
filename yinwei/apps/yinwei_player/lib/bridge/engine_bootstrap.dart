import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/bridge/native_engine.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';

enum EngineBackend { native, mock }

class EngineBootstrap {
  EngineBootstrap._(this.api, this.backend, this.detail);

  final EngineApi api;
  final EngineBackend backend;
  final String detail;

  static EngineBootstrap create() {
    final native = NativeEngine.tryCreate();
    if (native != null) {
      return EngineBootstrap._(
        native,
        EngineBackend.native,
        'Native · spatial_core',
      );
    }
    final why = YinweiBindings.loadError ?? 'spatial_core.dll 未找到';
    return EngineBootstrap._(
      MockEngine(),
      EngineBackend.mock,
      'Mock · 请运行 build_native_windows.ps1 · $why',
    );
  }
}
