import 'dart:io';

import 'package:yinwei_player/bridge/engine_api.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/bridge/native_engine.dart';
import 'package:yinwei_player/bridge/native_library_locator.dart';
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
      if (Platform.isIOS) {
        print('[YINWEI_IOS] ENGINE_BOOTSTRAP native');
      }
      return EngineBootstrap._(
        native,
        EngineBackend.native,
        native.supportsExtraSpeakers
            ? 'Native · spatial_core · extra-pts'
            : 'Native · spatial_core',
      );
    }
    if (Platform.isIOS) {
      print(
        '[YINWEI_IOS] ENGINE_BOOTSTRAP mock loadError=${YinweiBindings.loadError}',
      );
    }
    return EngineBootstrap._(
      MockEngine(),
      EngineBackend.mock,
      missingEngineDetailFor(
        NativeLibraryLocator.modeFor(
          isWindows: Platform.isWindows,
          isLinux: Platform.isLinux,
          isMacOS: Platform.isMacOS,
          isIOS: Platform.isIOS,
          isAndroid: Platform.isAndroid,
        ),
        YinweiBindings.loadError,
      ),
    );
  }

  static String missingEngineDetailFor(
    NativeLibraryLoadMode mode,
    String? loadError,
  ) {
    switch (mode) {
      case NativeLibraryLoadMode.iosProcess:
        return 'Mock · run tools/build_native_ios.sh · ${loadError ?? 'spatial_core not linked'}';
      case NativeLibraryLoadMode.windowsDll:
        return 'Mock · 请运行 build_native_windows.ps1 · ${loadError ?? 'spatial_core.dll 未找到'}';
      case NativeLibraryLoadMode.linuxSo:
      case NativeLibraryLoadMode.macDylib:
        return 'Mock · spatial_core unavailable · ${loadError ?? 'native library missing'}';
      case NativeLibraryLoadMode.androidUnavailable:
        return 'Android A2 · file engine preview · not connected';
    }
  }
}
