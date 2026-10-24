import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'listen_udp_protocol.dart';

/// The laptop's end of Listen audio over UDP
/// (docs/IMPLEMENTATION_LISTEN_UDP_AUDIO.md, phase 1).
///
/// - Bound only to the private route's Tailscale address, never 0.0.0.0.
/// - One audio session at a time. Its key is new for each session and is
///   only ever sent over the authenticated audio WebSocket ([offer]).
/// - Accepts a hello only from the address the private route already
///   verified (`tailscale whois`), signed with the session key; audio then
///   goes to exactly that address and port.
/// - Every packet is sent twice: now and [ListenUdp.repeatDelay] later.
/// - [healthy] turns false when the iPad's receiver reports stop for
///   [reportTimeout]; the gateway then returns to WebSocket audio.
class ListenUdpSender {
  ListenUdpSender._(this._socket) : _out = ListenUdpOutbox(_socket) {
    _socket.listen(_onEvent);
  }

  static const reportTimeout = Duration(seconds: 3);

  static Future<ListenUdpSender?> bind(
      InternetAddress address, int port) async {
    try {
      return ListenUdpSender._(await RawDatagramSocket.bind(address, port));
    } catch (_) {
      return null;
    }
  }

  final RawDatagramSocket _socket;
  final ListenUdpOutbox _out;
  int get port => _socket.port;

  Uint8List? _session, _key;
  InternetAddress? _peer;
  int? _peerPort;
  int _activatedUs = 0, _lastReportUs = 0;
  int _counter = 0;
  final _repeats = <({int dueUs, Uint8List packet})>[];
  final _clock = Stopwatch()..start();
  int get nowUs => _clock.elapsedMicroseconds;

  int sentPackets = 0, sentDatagrams = 0, repeats = 0, reports = 0;
  int rejectedHellos = 0, refusedPackets = 0;
  ListenUdpReport? lastReport;

  /// A hello was accepted: audio may be sent.
  bool get active => _peerPort != null;

  /// Active and the iPad's reports still arrive.
  bool healthy([int? at]) {
    if (!active) return false;
    final since = _lastReportUs > _activatedUs ? _lastReportUs : _activatedUs;
    return (at ?? nowUs) - since < reportTimeout.inMicroseconds;
  }

  /// Starts a new audio session for [peer] and returns what the iPad needs,
  /// for the `audioReady` message.
  Map<String, Object> offer(InternetAddress peer) {
    end();
    _session = ListenUdp.random(ListenUdp.sessionBytes);
    _key = ListenUdp.random(ListenUdp.keyBytes);
    _peer = peer;
    return {
      'port': port,
      'session': base64Encode(_session!),
      'key': base64Encode(_key!),
    };
  }

  /// The audio session ended: nothing more is sent or accepted.
  void end() {
    _session = _key = _peer = _peerPort = null;
    _repeats.clear();
    _out.clear();
  }

  /// Sends one YNO1 packet now and queues its repeat. False when the packet
  /// cannot go over UDP (no session, or larger than two datagrams): the
  /// gateway then sends it on the WebSocket.
  bool send(Uint8List packet, [int? at]) {
    final session = _session;
    if (session == null || !active) return false;
    final datagrams = ListenUdp.audio(session, ++_counter, packet);
    if (datagrams == null) {
      ++refusedPackets;
      return false;
    }
    _emit(datagrams);
    ++sentPackets;
    if (_repeats.length < 16) {
      _repeats.add((
        dueUs: (at ?? nowUs) + ListenUdp.repeatDelay.inMicroseconds,
        packet: packet
      ));
    }
    return true;
  }

  /// Sends the repeats that are due. Called on every gateway pump tick.
  void tick([int? at]) {
    final session = _session;
    if (session == null || !active) return;
    final now = at ?? nowUs;
    while (_repeats.isNotEmpty && _repeats.first.dueUs <= now) {
      final item = _repeats.removeAt(0);
      final datagrams =
          ListenUdp.audio(session, ++_counter, item.packet, repeat: true);
      if (datagrams != null) {
        _emit(datagrams);
        ++repeats;
      }
    }
  }

  void _emit(List<Uint8List> datagrams) {
    for (final d in datagrams) {
      _out.send(d, _peer!, _peerPort!);
      ++sentDatagrams;
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.write) {
      _out.flush();
      return;
    }
    if (event != RawSocketEvent.read) return;
    while (true) {
      final datagram = _socket.receive();
      if (datagram == null) return;
      final session = _session, key = _key, peer = _peer;
      if (session == null ||
          key == null ||
          peer == null ||
          datagram.address.address != peer.address ||
          datagram.data.length > 1400) {
        continue;
      }
      final data = datagram.data;
      final nonce = ListenUdp.helloNonce(data, session, key);
      if (nonce != null) {
        if (_peerPort != datagram.port) {
          _peerPort = datagram.port;
          _activatedUs = nowUs;
        }
        _out.send(ListenUdp.ack(session, nonce, key), peer, datagram.port);
        continue;
      }
      final report = ListenUdp.parseReport(data, session, key);
      if (report != null && datagram.port == _peerPort) {
        lastReport = report;
        _lastReportUs = nowUs;
        ++reports;
        continue;
      }
      ++rejectedHellos;
    }
  }

  Map<String, Object?> diagnostics() => {
        'active': active,
        'healthy': healthy(),
        'sentPackets': sentPackets,
        'repeats': repeats,
        'reports': reports,
        'refusedPackets': refusedPackets,
        'socketDropped': _out.dropped,
        'rejected': rejectedHellos,
        if (lastReport != null) ...{
          'peerLost': lastReport!.lostPackets,
          'peerRecovered': lastReport!.recoveredPackets,
          'peerBufferMs': lastReport!.bufferMs,
        },
      };

  void close() {
    end();
    _socket.close();
  }
}
