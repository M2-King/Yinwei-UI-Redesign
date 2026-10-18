import 'dart:collection';
import 'dart:typed_data';

/// Wire input has one fixed format. Resampling belongs at the capture edge,
/// never in the laptop gateway or a second spatial processor.
class RemoteInputFrame {
  RemoteInputFrame._(this.bytes, this.epoch, this.sequence, this.firstFrame,
      this.discontinuous);

  static const headerBytes = 48;
  static const frames = 480;
  static const channels = 2;
  static const sampleRate = 48000;
  static const packetBytes = headerBytes + frames * channels * 2;
  static const maxInteger = 0x1fffffffffffff;
  final Uint8List bytes;
  final int epoch, sequence, firstFrame;
  final bool discontinuous;

  Int16List get pcm {
    // Decode explicitly: the wire is little endian even on another host.
    final data = ByteData.sublistView(bytes);
    return Int16List.fromList(List.generate(frames * channels,
        (i) => data.getInt16(headerBytes + i * 2, Endian.little)));
  }

  static RemoteInputFrame decode(List<int> message) {
    if (message.length != packetBytes) {
      throw const FormatException('invalid_input_size');
    }
    final bytes = Uint8List.fromList(message);
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != 0x31494e59 ||
        data.getUint32(4, Endian.little) != 1 ||
        data.getUint32(32, Endian.little) != sampleRate ||
        data.getUint32(36, Endian.little) != frames ||
        data.getUint32(40, Endian.little) != channels ||
        data.getUint32(44, Endian.little) > 1) {
      throw const FormatException('invalid_input_format');
    }
    final epoch = data.getUint64(8, Endian.little);
    final sequence = data.getUint64(16, Endian.little);
    final firstFrame = data.getUint64(24, Endian.little);
    if (epoch <= 0 ||
        epoch > maxInteger ||
        sequence <= 0 ||
        sequence > maxInteger ||
        firstFrame < 0 ||
        firstFrame > maxInteger - frames) {
      throw const FormatException('invalid_input_position');
    }
    return RemoteInputFrame._(bytes, epoch, sequence, firstFrame,
        data.getUint32(44, Endian.little) == 1);
  }

  static Uint8List encode(
      {required int epoch,
      required int sequence,
      required int firstFrame,
      required Int16List pcm,
      bool discontinuous = false}) {
    if (pcm.length != frames * channels ||
        epoch <= 0 ||
        epoch > maxInteger ||
        sequence <= 0 ||
        sequence > maxInteger ||
        firstFrame < 0 ||
        firstFrame > maxInteger - frames) {
      throw ArgumentError('Invalid input frame');
    }
    final bytes = Uint8List(packetBytes);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x31494e59, Endian.little); // YNI1
    data.setUint32(4, 1, Endian.little);
    data.setUint64(8, epoch, Endian.little);
    data.setUint64(16, sequence, Endian.little);
    data.setUint64(24, firstFrame, Endian.little);
    data.setUint32(32, sampleRate, Endian.little);
    data.setUint32(36, frames, Endian.little);
    data.setUint32(40, channels, Endian.little);
    data.setUint32(44, discontinuous ? 1 : 0, Endian.little);
    for (var i = 0; i < pcm.length; ++i) {
      data.setInt16(headerBytes + i * 2, pcm[i], Endian.little);
    }
    return bytes;
  }
}

/// R2 installs an epoch-owned Rust ingress/output adapter. R1 injects a
/// synthetic adapter only in tests. Methods must be bounded and nonblocking.
abstract class RemoteTransformAdapter {
  bool get available;
  void start(int epoch);
  bool tryPush(RemoteInputFrame frame, {required bool discontinuous});
  Uint8List? read();
  void stop();
  void close() => stop();
}

/// Numeric validation, token bucket and a short bounded in-memory backlog.
class RemoteTransformFlow {
  RemoteTransformFlow(this.epoch, this.adapter, {DateTime Function()? now})
      : _now = now ?? DateTime.now {
    _updated = _now();
    lastInput = _updated;
  }

  // Windows must cover the internet round trip (iPad → tunnel → laptop and
  // back). At 8 × 10 ms the uplink stalled whenever the RTT exceeded 80 ms,
  // dropping frames and forcing output resets. 32 frames = 320 ms of audio.
  static const inputCredit = 32;
  static const outputCredit = 64;
  // Laptop bundles released before the wider windows advertise these; clients
  // still accept them so a new iPad build works with an older laptop.
  static const legacyInputCredit = 8;
  static const legacyOutputCredit = 24;
  static const backlogFrames = inputCredit;
  final _backlog = ListQueue<(RemoteInputFrame, bool)>();
  final int epoch;
  final RemoteTransformAdapter adapter;
  final DateTime Function() _now;
  late DateTime _updated, lastInput;
  double _tokens = inputCredit.toDouble();
  int _lastSequence = 0, _nextFrame = 0;
  int accepted = 0, dropped = 0;
  bool _gap = true;

  Map<String, Object> push(List<int> bytes) {
    final frame = RemoteInputFrame.decode(bytes);
    if (frame.epoch != epoch ||
        frame.sequence <= _lastSequence ||
        frame.firstFrame < _nextFrame ||
        ((!frame.discontinuous && _lastSequence != 0) &&
            (frame.sequence != _lastSequence + 1 ||
                frame.firstFrame != _nextFrame))) {
      throw const FormatException('stale_input');
    }
    final now = _now();
    final elapsed = now.difference(_updated).inMicroseconds;
    _tokens = (_tokens + elapsed.clamp(0, 1000000) / 10000)
        .clamp(0, inputCredit)
        .toDouble();
    _updated = now;
    if (_tokens < 1) throw const FormatException('input_rate_limited');
    --_tokens;
    _lastSequence = frame.sequence;
    _nextFrame = frame.firstFrame + RemoteInputFrame.frames;
    lastInput = now;
    // Network frames arrive in bursts, but the native ingress queue holds
    // only ~43 ms and rejects input while its worker holds the lock. Keep a
    // short ordered backlog and retry it from the 10 ms pump instead of
    // dropping: each drop forces an output reset that flushes the listener.
    final discontinuous = _gap || frame.discontinuous;
    final queued = _backlog.length < backlogFrames;
    if (queued) {
      _backlog.add((frame, discontinuous));
      _gap = false;
      ++accepted;
    } else {
      _gap = true;
      ++dropped;
    }
    drain();
    return {
      'type': 'inputAck',
      'sequence': frame.sequence,
      'epoch': epoch,
      'accepted': queued,
      'resetOutput': queued && discontinuous,
      'dropped': dropped
    };
  }

  /// Push backlogged frames in order until the adapter is full.
  void drain() {
    while (_backlog.isNotEmpty) {
      final (frame, discontinuous) = _backlog.first;
      if (!adapter.tryPush(frame, discontinuous: discontinuous)) return;
      _backlog.removeFirst();
    }
  }
}

/// Shared validation on both ends of the unmodified YNW1 downlink.
class RemoteOutputValidator {
  RemoteOutputValidator(this.epoch);
  final int epoch;
  int _lastOutput = 0, _lastOutputFrame = 0;

  int validate(Uint8List bytes) {
    if (bytes.length < 64 || bytes.length > 56 + 512 * 8) {
      throw const FormatException('invalid_output_size');
    }
    final data = ByteData.sublistView(bytes);
    final sequence = data.getUint64(16, Endian.little);
    final firstFrame = data.getUint64(24, Endian.little);
    final count = data.getUint32(36, Endian.little);
    if (data.getUint32(0, Endian.little) != 0x31574e59 ||
        data.getUint32(4, Endian.little) != 1 ||
        data.getUint64(8, Endian.little) != epoch ||
        data.getUint32(32, Endian.little) != RemoteInputFrame.sampleRate ||
        count == 0 ||
        count > 512 ||
        bytes.length != 56 + count * 8 ||
        sequence <= _lastOutput ||
        sequence > RemoteInputFrame.maxInteger ||
        firstFrame < _lastOutputFrame ||
        firstFrame > RemoteInputFrame.maxInteger - count ||
        data.getUint32(40, Endian.little) > 1 ||
        !data.getFloat32(48, Endian.little).isFinite ||
        !data.getFloat32(52, Endian.little).isFinite) {
      throw const FormatException('invalid_output_format');
    }
    for (var offset = 56; offset < bytes.length; offset += 4) {
      if (!data.getFloat32(offset, Endian.little).isFinite) {
        throw const FormatException('invalid_output_sample');
      }
    }
    _lastOutput = sequence;
    _lastOutputFrame = firstFrame + count;
    return sequence;
  }
}
