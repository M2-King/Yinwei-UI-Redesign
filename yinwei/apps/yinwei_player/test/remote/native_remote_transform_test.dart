import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/native_remote_transform.dart';
import 'package:yinwei_player/remote/remote_transform.dart';
import 'transform_test_support.dart';

void main() {
  final path = Platform.environment['YINWEI_R2_NATIVE_DLL'];
  test('real native ABI renders Original and Spatial without a playback device',
      () async {
    final lib = DynamicLibrary.open(path!);
    final mode = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'yinwei_set_mode');
    var sourceIdle = true;
    var configuration = 'initial';
    final adapter = NativeRemoteTransform.tryCreate(
        libraryPath: path,
        sourceAvailable: () => sourceIdle,
        configuration: () => configuration)!;
    try {
      for (final playbackMode in [0, 1]) {
        expect(mode(playbackMode), 0);
        final epoch = 200 + playbackMode;
        adapter.start(epoch);
        var gap = true;
        Uint8List? wet;
        // HRIR initialization happens on the worker. Input is bounded and
        // source-frame positions remain monotonic across deliberate gap drops.
        for (var i = 1; i <= 2000 && wet == null; ++i) {
          final accepted = adapter.tryPush(
              RemoteInputFrame.decode(RemoteInputFrame.encode(
                  epoch: epoch,
                  sequence: i,
                  firstFrame: (i - 1) * 480,
                  pcm: syntheticInput(),
                  discontinuous: gap)),
              discontinuous: gap);
          gap = !accepted;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          wet = adapter.read();
        }
        expect(wet, isNotNull);
        final data = ByteData.sublistView(wet!);
        expect(data.getUint64(8, Endian.little), epoch);
        expect(data.getUint32(40, Endian.little), playbackMode);
        final first = data.getUint64(24, Endian.little);
        var differs = false;
        for (var i = 0; i < 1024; ++i) {
          final sample = data.getFloat32(56 + i * 4, Endian.little);
          final dry = syntheticInput()[(first * 2 + i) % 960] / 32768;
          expect(sample.isFinite, true);
          if (playbackMode == 0) {
            expect(sample, dry);
          } else if ((sample - dry).abs() > .00001) {
            differs = true;
          }
        }
        if (playbackMode == 1) expect(differs, true);
        sourceIdle = false;
        expect(adapter.available, false);
        expect(adapter.read, throwsStateError);
        sourceIdle = true;
        configuration = 'changed';
        expect(adapter.available, false);
        adapter.stop();
        expect(adapter.read(), isNull);
        configuration = 'initial';
      }
    } finally {
      adapter.close();
    }
  },
      skip: path == null
          ? 'Requires an explicitly supplied built native test library'
          : false);
}
