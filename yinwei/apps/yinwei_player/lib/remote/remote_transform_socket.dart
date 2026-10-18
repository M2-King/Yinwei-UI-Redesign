import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'remote_transform.dart';

/// One source lease; cleanup is synchronous so no reconnect sees old PCM.
class RemoteTransformSocket {
  RemoteTransformSocket(
      {required this.socket,
      required this.adapter,
      required this.epoch,
      required this.sessionValid,
      required this.consumeTicket,
      required this.onClosed,
      this.onStarted}) {
    _deadline = Timer(const Duration(seconds: 5), () {
      if (_flow == null) close('authentication_required');
    });
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _pump());
    socket.pingInterval = const Duration(seconds: 10);
    socket.listen(_receive, onDone: dispose, onError: (Object _) => dispose());
  }

  final WebSocket socket;
  final RemoteTransformAdapter adapter;
  final int epoch;
  final bool Function() sessionValid;
  final bool Function(String) consumeTicket;
  final void Function() onClosed;
  final void Function()? onStarted;
  late final Timer _timer, _deadline;
  RemoteTransformFlow? _flow;
  RemoteOutputValidator? _output;
  final _outstanding = <int, DateTime>{};
  int _lastAck = 0;
  bool _closed = false, _adapterStarted = false;
  double _controlTokens = 32;
  DateTime _controlUpdated = DateTime.now();

  void _receive(dynamic message) {
    if (_closed) return;
    if (!sessionValid()) {
      close('session_revoked');
      return;
    }
    try {
      if (message is List<int>) {
        if (_flow == null || message.length > 2048) {
          close('invalid_message');
          return;
        }
        socket.add(jsonEncode(_flow!.push(message)));
        return;
      }
      if (message is! String || utf8.encode(message).length > 2048) {
        close('invalid_message');
        return;
      }
      final data = jsonDecode(message);
      final controlNow = DateTime.now();
      _controlTokens = (_controlTokens +
              controlNow
                      .difference(_controlUpdated)
                      .inMicroseconds
                      .clamp(0, 1000000) /
                  4000)
          .clamp(0, 32)
          .toDouble();
      _controlUpdated = controlNow;
      if (_controlTokens < 1) {
        close('control_rate_limited');
        return;
      }
      --_controlTokens;
      if (data is! Map || data.length != 1) {
        close('invalid_message');
        return;
      }
      if (_flow == null) {
        if (data['ticket'] is! String ||
            !consumeTicket(data['ticket'] as String)) {
          close('invalid_ticket');
          return;
        }
        if (!adapter.available) {
          close('transform_unavailable');
          return;
        }
        // stop() also runs when start() throws after partial allocation.
        _adapterStarted = true;
        adapter.start(epoch);
        onStarted?.call();
        _flow = RemoteTransformFlow(epoch, adapter);
        _output = RemoteOutputValidator(epoch);
        _deadline.cancel();
        socket.add(jsonEncode({
          'type': 'transformReady',
          'epoch': epoch,
          'inputFormat': 'YNI1',
          'outputFormat': 'YNW1',
          'sampleRate': RemoteInputFrame.sampleRate,
          'frames': RemoteInputFrame.frames,
          'channels': RemoteInputFrame.channels,
          'inputCredit': RemoteTransformFlow.inputCredit,
          'outputCredit': RemoteTransformFlow.outputCredit
        }));
      } else if (data['ack'] is int &&
          data['ack'] > 0 &&
          (data['ack'] <= _lastAck || _outstanding.containsKey(data['ack']))) {
        final ack = data['ack'] as int;
        if (ack > _lastAck) {
          _outstanding.removeWhere((sequence, _) => sequence <= ack);
          _lastAck = ack;
        }
      } else {
        close('invalid_output_ack');
      }
    } on FormatException catch (error) {
      close(error.message);
    } catch (_) {
      close('transform_failed');
    }
  }

  void _pump() {
    if (_closed) return;
    if (!sessionValid()) {
      close('session_revoked');
      return;
    }
    final flow = _flow;
    if (flow == null) return;
    if (!adapter.available) {
      close('local_source_changed');
      return;
    }
    final now = DateTime.now();
    if (now.difference(flow.lastInput) > const Duration(seconds: 5)) {
      close('input_idle');
      return;
    }
    if (_outstanding.isNotEmpty &&
        now.difference(_outstanding.values.first) >
            const Duration(seconds: 5)) {
      close('slow_client');
      return;
    }
    try {
      flow.drain();
      for (var i = 0;
          // Up to 4 packets per tick: Windows timers can fire every ~15.6 ms,
          // and the link must catch up after a network stall.
          i < 4 && _outstanding.length < RemoteTransformFlow.outputCredit;
          ++i) {
        final Uint8List? packet = adapter.read();
        if (packet == null) break;
        final sequence = _output!.validate(packet);
        _outstanding[sequence] = now;
        socket.add(packet);
      }
    } catch (_) {
      close('transform_output_failed');
    }
  }

  void close(String reason) {
    if (_closed) return;
    dispose();
    unawaited(socket.close(1008, reason));
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _deadline.cancel();
    _outstanding.clear();
    _flow = null;
    _output = null;
    if (_adapterStarted) {
      try {
        adapter.stop();
      } catch (_) {}
    }
    onClosed();
  }
}
