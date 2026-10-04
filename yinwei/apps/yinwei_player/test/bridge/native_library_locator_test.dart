import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/native_library_locator.dart';

void main() {
  test('macOS resolves its bundled dylib independently of cwd', () {
    expect(
      NativeLibraryLocator.macOSLibraryPath(
        '/Applications/音围 Yinwei.app/Contents/MacOS/Yinwei',
      ),
      '/Applications/音围 Yinwei.app/Contents/Frameworks/libspatial_core.dylib',
    );
    expect(
      NativeLibraryLocator.modeFor(
        isWindows: false,
        isLinux: false,
        isMacOS: true,
        isIOS: false,
      ),
      NativeLibraryLoadMode.macDylib,
    );
  });

  test('macOS refuses non-bundle paths instead of searching stale libraries',
      () {
    for (final path in [
      'Yinwei.app/Contents/MacOS/Yinwei',
      '/usr/local/bin/dart',
      '/Applications/Yinwei.app/Contents/Yinwei',
    ]) {
      expect(() => NativeLibraryLocator.macOSLibraryPath(path),
          throwsArgumentError);
    }
  });

  test('iOS loads spatial_core from the current process, not a Windows DLL',
      () {
    expect(
      NativeLibraryLocator.modeFor(
        isWindows: false,
        isLinux: false,
        isMacOS: false,
        isIOS: true,
      ),
      NativeLibraryLoadMode.iosProcess,
    );
    expect(NativeLibraryLocator.processToken, 'process');
  });

  test('Windows keeps the DLL search path', () {
    expect(
      NativeLibraryLocator.modeFor(
        isWindows: true,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
      ),
      NativeLibraryLoadMode.windowsDll,
    );
  });

  test(
      'Android A2 file engine stays unavailable while JNI capture uses spatial_core',
      () {
    expect(
      NativeLibraryLocator.modeFor(
        isWindows: false,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
        isAndroid: true,
      ),
      NativeLibraryLoadMode.androidUnavailable,
    );
    final detail = EngineBootstrap.missingEngineDetailFor(
      NativeLibraryLoadMode.androidUnavailable,
      'not connected',
    );
    expect(detail.toLowerCase(), contains('android a2'));
    expect(detail.toLowerCase(), contains('file engine'));
    expect(detail.toLowerCase(), isNot(contains('dll')));
    expect(detail, contains('not connected'));
    expect(detail.toLowerCase(), isNot(contains('bad state')));
    final messy = EngineBootstrap.missingEngineDetailFor(
      NativeLibraryLoadMode.androidUnavailable,
      'Bad state: spatial_core is not connected on Android A2 file-engine preview',
    );
    expect(messy.toLowerCase(), isNot(contains('bad state')));
    expect(messy.toLowerCase(), isNot(contains('failed')));
  });

  test('unknown hosts stay explicit unsupported platforms', () {
    expect(
      () => NativeLibraryLocator.modeFor(
        isWindows: false,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('missing-engine copy never mentions spatial_core.dll on iOS', () {
    final detail = EngineBootstrap.missingEngineDetailFor(
      NativeLibraryLoadMode.iosProcess,
      'symbols missing',
    );
    expect(detail.toLowerCase(), isNot(contains('dll')));
    expect(detail.toLowerCase(), isNot(contains('windows')));
    expect(detail, contains('build_native_ios.sh'));
    expect(detail, contains('symbols missing'));
  });
}
