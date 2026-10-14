import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/remote/native_output_tap.dart';

void main() {
  test('old file-streaming DLL leaves the optional live tap unavailable', () {
    final path = Platform.environment['YINWEI_NATIVE_FILE_ONLY_TEST_DLL'];
    if (path == null) return;
    final original = YinweiBindings.resolvedLibraryPath;
    YinweiBindings.resolvedLibraryPath = path;
    try {
      expect(NativeOutputTap.tryCreate(live: true), isNull);
      final file = NativeOutputTap.tryCreate();
      expect(file, isNotNull);
      file?.close();
    } finally {
      YinweiBindings.resolvedLibraryPath = original;
    }
  });
  test(
      'new live ABI stays inactive and never starts a live engine when queried',
      () {
    final path = Platform.environment['YINWEI_NATIVE_TAP_TEST_DLL'];
    if (path == null) return;
    final library = DynamicLibrary.open(path);
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
        'yinwei_live_output_tap_version');
    final running = library.lookupFunction<Int32 Function(), int Function()>(
        'yinwei_live_is_running');
    final read = library.lookupFunction<
        Int32 Function(Pointer<Float>, Uint32, Pointer<OutputTapMetaC>),
        int Function(Pointer<Float>, int,
            Pointer<OutputTapMetaC>)>('yinwei_live_output_tap_read');
    expect(version(), 1);
    expect(read(nullptr, 512, nullptr), -3);
    expect(running(), 0);
    final original = YinweiBindings.resolvedLibraryPath;
    YinweiBindings.resolvedLibraryPath = path;
    try {
      final tap = NativeOutputTap.tryCreate(live: true);
      expect(tap, isNotNull);
      tap!.setEnabled(false);
      expect(tap.read(), isNull);
      tap.close();
      expect(running(), 0);
    } finally {
      YinweiBindings.resolvedLibraryPath = original;
    }
  });
  test('older native DLL keeps local playback and reports tap unavailable', () {
    final path = Platform.environment['YINWEI_NATIVE_OLD_TEST_DLL'];
    if (path == null) return;
    final original = YinweiBindings.resolvedLibraryPath;
    YinweiBindings.resolvedLibraryPath = path;
    try {
      expect(NativeOutputTap.tryCreate(), isNull);
    } finally {
      YinweiBindings.resolvedLibraryPath = original;
    }
  });
  test(
      'matched native DLL exposes additive tap ABI without opening an audio device',
      () {
    final path = Platform.environment['YINWEI_NATIVE_TAP_TEST_DLL'];
    if (path == null) return;
    final library = DynamicLibrary.open(path);
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
        'yinwei_output_tap_version');
    final read = library.lookupFunction<
        Int32 Function(Pointer<Float>, Uint32, Pointer<OutputTapMetaC>),
        int Function(Pointer<Float>, int,
            Pointer<OutputTapMetaC>)>('yinwei_output_tap_read');
    expect(version(), 1);
    expect(sizeOf<OutputTapMetaC>(), 48);
    expect(read(nullptr, 512, nullptr), -3);
    final original = YinweiBindings.resolvedLibraryPath;
    YinweiBindings.resolvedLibraryPath = path;
    try {
      final tap = NativeOutputTap.tryCreate();
      expect(tap, isNotNull);
      tap!.setEnabled(true);
      expect(tap.read(), isNull);
      tap.setEnabled(false);
      tap.close();
      tap.close();
    } finally {
      YinweiBindings.resolvedLibraryPath = original;
    }
  });
}
