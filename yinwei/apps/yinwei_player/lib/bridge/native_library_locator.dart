/// How Dart FFI locates `spatial_core` on each host.
///
/// iOS links `libspatial_core.a` into the Runner process. Lookups must use
/// [DynamicLibrary.process], never a Windows DLL path.
enum NativeLibraryLoadMode {
  windowsDll,
  linuxSo,
  macDylib,
  iosProcess,
  androidUnavailable,
}

abstract final class NativeLibraryLocator {
  static const processToken = 'process';

  static NativeLibraryLoadMode modeFor({
    required bool isWindows,
    required bool isLinux,
    required bool isMacOS,
    required bool isIOS,
    bool isAndroid = false,
  }) {
    if (isWindows) return NativeLibraryLoadMode.windowsDll;
    if (isLinux) return NativeLibraryLoadMode.linuxSo;
    if (isMacOS) return NativeLibraryLoadMode.macDylib;
    if (isIOS) return NativeLibraryLoadMode.iosProcess;
    if (isAndroid) return NativeLibraryLoadMode.androidUnavailable;
    throw UnsupportedError('Unsupported platform');
  }
}
