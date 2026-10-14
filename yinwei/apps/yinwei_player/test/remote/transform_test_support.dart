import 'dart:collection';
import 'dart:typed_data';

import 'package:yinwei_player/remote/remote_transform.dart';

/// Test-only format conversion. This is not HRTF/DSP or a production adapter.
class SyntheticTransformAdapter implements RemoteTransformAdapter {
  final Queue<Uint8List> _output = Queue();
  @override
  bool available = true;
  bool holdOutput = false, failStart = false, corruptOutput = false;
  bool started = false;
  int epoch = 0, starts = 0, stops = 0, pushes = 0, peakQueued = 0;
  final List<bool> gaps = [];
  int get queued => _output.length;

  @override
  void start(int value) {
    ++starts;
    epoch = value;
    started = true;
    _output.clear();
    gaps.clear();
    if (failStart) throw StateError('Synthetic start failure');
  }

  @override
  bool tryPush(RemoteInputFrame frame, {required bool discontinuous}) {
    if (!started || frame.epoch != epoch || _output.length >= 8) return false;
    ++pushes;
    gaps.add(discontinuous);
    final bytes = Uint8List(56 + RemoteInputFrame.frames * 8);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x31574e59, Endian.little);
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, epoch, Endian.little);
    data.setUint64(16, frame.sequence, Endian.little);
    data.setUint64(24, frame.firstFrame, Endian.little);
    data.setUint32(32, 48000, Endian.little);
    data.setUint32(36, 480, Endian.little);
    final pcm = frame.pcm;
    for (var i = 0; i < pcm.length; ++i) {
      data.setFloat32(56 + i * 4, pcm[i] / 32768, Endian.little);
    }
    if (corruptOutput) data.setFloat32(56, double.nan, Endian.little);
    _output.add(bytes);
    if (_output.length > peakQueued) peakQueued = _output.length;
    return true;
  }

  @override
  Uint8List? read() =>
      !started || holdOutput || _output.isEmpty ? null : _output.removeFirst();

  @override
  void stop() {
    ++stops;
    started = false;
    _output.clear();
  }
}

Int16List syntheticInput() => Int16List.fromList(
    List.generate(960, (i) => [-32768, -15000, 0, 15000, 32767][i % 5]));
