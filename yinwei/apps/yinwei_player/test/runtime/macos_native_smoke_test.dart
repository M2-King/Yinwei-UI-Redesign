import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/native_engine.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';

// Flutter tests run outside an .app. Supply an explicit library for this test
// only; the shipping loader still requires Contents/Frameworks.
// YINWEI_MACOS_DYLIB=/absolute/libspatial_core.dylib flutter test --no-pub \
//   test/runtime/macos_native_smoke_test.dart
void main() {
  final library = Platform.environment['YINWEI_MACOS_DYLIB'];
  test('macOS native FFI opens, spatializes and exports a real PCM fixture',
      () async {
    expect(library, isNotNull,
        reason: 'Set YINWEI_MACOS_DYLIB to the built library absolute path.');
    expect(File(library!).isAbsolute, isTrue);
    YinweiBindings.loadFromPath(library);
    final native = NativeEngine.tryCreate();
    expect(native, isNotNull, reason: YinweiBindings.loadError);
    final ctrl = EngineController(engine: native!, backendLabel: 'Native');
    final dir = await Directory.systemTemp.createTemp('yinwei-macos-');
    addTearDown(() async {
      ctrl.dispose();
      await dir.delete(recursive: true);
    });
    final wav = File('${dir.path}/音围 sample.wav');
    await wav.writeAsBytes(_sineWav());
    await ctrl.openPath(wav.path);
    expect(ctrl.hasOpenedFile, isTrue);
    await ctrl.setMode(PlaybackMode.original);
    expect(ctrl.mode, PlaybackMode.original);
    await ctrl.setMode(PlaybackMode.spatial);
    expect(ctrl.mode, PlaybackMode.spatial);
    final output = '${dir.path}/spatial export.wav';
    await ctrl.exportWav(output);
    expect(await File(output).length(), greaterThan(44));
    expect(YinweiBindings.resolvedLibraryPath, library);
  },
      skip: !Platform.isMacOS
          ? 'Requires a built macOS dylib on a Mac.'
          : library == null
              ? 'Set YINWEI_MACOS_DYLIB to opt into native Mac verification.'
              : false);
}

Uint8List _sineWav() {
  const rate = 44100;
  const frames = rate ~/ 4;
  final bytes = ByteData(44 + frames * 4);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 2, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 4, Endian.little);
  bytes.setUint16(32, 4, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    final sample = (math.sin(2 * math.pi * 440 * i / rate) * 3200).round();
    bytes.setInt16(44 + i * 4, sample, Endian.little);
    bytes.setInt16(46 + i * 4, sample, Endian.little);
  }
  return bytes.buffer.asUint8List();
}
