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

  /// Resolve only from the running .app, never cwd or the library search path.
  /// The same absolute path is reused by background isolates.
  static String macOSLibraryPath(String executablePath) {
    final executable = Uri.file(executablePath, windows: false);
    final segments = executable.pathSegments;
    if (!executablePath.startsWith('/') ||
        segments.length < 4 ||
        segments[segments.length - 3] != 'Contents' ||
        segments[segments.length - 2] != 'MacOS' ||
        !segments[segments.length - 4].endsWith('.app') ||
        segments.last.isEmpty) {
      throw ArgumentError.value(
        executablePath,
        'executablePath',
        'Expected an absolute .app/Contents/MacOS executable path',
      );
    }
    return executable
        .resolve('../Frameworks/libspatial_core.dylib')
        .toFilePath(windows: false);
  }

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
