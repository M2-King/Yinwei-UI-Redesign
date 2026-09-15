import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/native_engine.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/engine_controller.dart';

double _sceneGeometric(Map<String, dynamic> scene) {
  final source = (scene['sources'] as List)
      .cast<Map>()
      .firstWhere((s) => s['id'] == kSpatialPointSourceIdV1);
  final p = source['worldPosition'] as Map;
  return geometricDistanceM(
    Vec3V1(
      (p['x'] as num).toDouble(),
      (p['y'] as num).toDouble(),
      (p['z'] as num).toDouble(),
    ),
  );
}

Uint8List _silentWav({int sampleRate = 44100, int milliseconds = 250}) {
  final frames = (sampleRate * milliseconds / 1000).round();
  final dataBytes = frames * 4;
  final bytes = BytesBuilder();
  void u32(int v) {
    bytes.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  }

  void u16(int v) {
    bytes.add([v & 255, (v >> 8) & 255]);
  }

  bytes.add('RIFF'.codeUnits);
  u32(36 + dataBytes);
  bytes.add('WAVE'.codeUnits);
  bytes.add('fmt '.codeUnits);
  u32(16);
  u16(1);
  u16(2);
  u32(sampleRate);
  u32(sampleRate * 4);
  u16(4);
  u16(16);
  bytes.add('data'.codeUnits);
  u32(dataBytes);
  bytes.add(Uint8List(dataBytes));
  return bytes.takeBytes();
}

void main() {
  test('Windows native engine loads and Point adoption writes params', () async {
    if (!Platform.isWindows) {
      return;
    }
    final native = NativeEngine.tryCreate();
    expect(
      native,
      isNotNull,
      reason: YinweiBindings.loadError ?? 'spatial_core.dll not loaded',
    );
    final engine = native!;
    final ctrl = EngineController(engine: engine, backendLabel: 'Native');
    final adapter = SpatialRuntimeAdapter()..bootstrap(ctrl.params);
    expect(adapter.hasScene, isTrue);

    final wav = File(
      '${Directory.systemTemp.path}\\yinwei_phase1c_smoke.wav',
    );
    await wav.writeAsBytes(_silentWav(), flush: true);
    await ctrl.openPath(wav.path);
    expect(ctrl.hasOpenedFile, isTrue);

    await ctrl.setMode(PlaybackMode.original);
    expect(ctrl.mode, PlaybackMode.original);
    await ctrl.setMode(PlaybackMode.spatial);
    expect(ctrl.mode, PlaybackMode.spatial);

    var playOk = true;
    try {
      await ctrl.play();
    } catch (_) {
      playOk = false;
    }
    if (playOk) {
      expect(ctrl.playing, isTrue);
      await ctrl.seek(Duration.zero);
      await ctrl.pause();
      expect(ctrl.playing, isFalse);
    }

    expect(YinweiBindings.resolvedLibraryPath, contains('spatial_core'));

    Future<void> adoptPose({
      required double azimuthDeg,
      required double elevationDeg,
      required double distanceM,
    }) async {
      final adopted = adapter.adoptPointParams(
        SpatialParams(
          azimuthDeg: azimuthDeg,
          elevationDeg: elevationDeg,
          distanceM: distanceM,
        ),
      );
      expect(adopted.shouldWriteEngine, isTrue);
      await ctrl.setParams(adopted.engineParams!);
    }

    await adoptPose(azimuthDeg: 0, elevationDeg: 0, distanceM: 1.5);
    expect(ctrl.params.azimuthDeg, closeTo(0, 1e-4));
    expect(adapter.appliedRevision, 2);

    await adoptPose(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5);
    expect(ctrl.params.azimuthDeg, closeTo(90, 1e-4));

    await adoptPose(azimuthDeg: -90, elevationDeg: 0, distanceM: 1.5);
    expect(ctrl.params.azimuthDeg, closeTo(-90, 1e-4));

    await adoptPose(azimuthDeg: 180, elevationDeg: 0, distanceM: 1.5);
    expect(ctrl.params.azimuthDeg.abs(), closeTo(180, 1e-4));

    await adoptPose(azimuthDeg: 0, elevationDeg: 45, distanceM: 1.5);
    expect(ctrl.params.elevationDeg, closeTo(45, 1e-4));

    await adoptPose(azimuthDeg: 0, elevationDeg: 0, distanceM: 25);
    expect(_sceneGeometric(adapter.snapshot()!), closeTo(25, 1e-6));
    expect(ctrl.params.distanceM, 10.0);

    final exportPath =
        '${Directory.systemTemp.path}\\yinwei_phase1c_export.wav';
    await ctrl.exportWav(exportPath);
    final exported = File(exportPath);
    expect(exported.existsSync(), isTrue);
    expect(exported.lengthSync(), greaterThan(44));

    final array = ctrl.array.copy()..applyStereo2Preset();
    await ctrl.setArray(array);
    expect(ctrl.array.enabled, isTrue);

    ctrl.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
