import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'listen_udp_protocol.dart';

/// The iPad's end of Listen audio over UDP
/// (docs/IMPLEMENTATION_LISTEN_UDP_AUDIO.md, phase 1).
///
/// [connect] sends signed hellos to the laptop's Tailscale address until the
/// laptop answers, then hands every reassembled YNO1 packet to [onPacket].
/// Ordering, duplicate drop and gap concealment happen in
/// [ListenPacketOrderer], shared with the WebSocket path.
class ListenUdpReceiver {
  ListenUdpReceiver._(this._socket, this._laptop, this._port, this._session,
      this._key, this._onPacket)
      : _out = ListenUdpOutbox(_socket, limit: 8);

  static const helloEvery = Duration(milliseconds: 300);
  static const connectTimeout = Duration(milliseconds: 1500);

  static Future<ListenUdpReceiver?> connect({
    required InternetAddress laptop,
    required int port,
    required Uint8List session,
    required Uint8List key,
    required void Function(Uint8List packet, bool repeat) onPacket,
  }) async {
    if (session.length != ListenUdp.sessionBytes ||
        key.length != ListenUdp.keyBytes ||
        port <= 0 ||
        port > 65535) {
      return null;
    }
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
          laptop.type == InternetAddressType.IPv6
              ? InternetAddress.anyIPv6
              : InternetAddress.anyIPv4,
          0);
    } catch (_) {
      return null;
    }
    final receiver =
        ListenUdpReceiver._(socket, laptop, port, session, key, onPacket);
    if (await receiver._handshake()) return receiver;
    receiver.close();
    return null;
  }

  final RawDatagramSocket _socket;
  final ListenUdpOutbox _out;
  final InternetAddress _laptop;
  final int _port;
  final Uint8List _session, _key;
  final void Function(Uint8List packet, bool repeat) _onPacket;
  final _reassembler = ListenUdpReassembler();
  final _clock = Stopwatch()..start();
  Completer<bool>? _acked;
  Uint8List? _nonce;
  int _reportCounter = 0;
  bool _closed = false;

  int datagrams = 0, packets = 0, repeatsUsed = 0;
  int lastAudioUs = -1;

  /// Sequences whose first copy arrived, to count repeats that filled a hole.
  final _firstSeen = <int>{};

  int get nowUs => _clock.elapsedMicroseconds;

  Future<bool> _handshake() async {
    final acked = _acked = Completer<bool>();
    _nonce = ListenUdp.random(ListenUdp.nonceBytes);
    _socket.listen(_onEvent);
    final deadline = DateTime.now().add(connectTimeout);
    while (!acked.isCompleted && DateTime.now().isBefore(deadline)) {
      _sendTo(ListenUdp.hello(_session, _nonce!, _key));
      await Future.any([acked.future, Future<void>.delayed(helloEvery)]);
    }
    return acked.isCompleted;
  }

  void _sendTo(Uint8List data) {
    if (_closed) return;
    _out.send(data, _laptop, _port);
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
      if (datagram.address.address != _laptop.address ||
          datagram.port != _port ||
          datagram.data.length > 1400) {
        continue;
      }
      final data = datagram.data;
      final acked = _acked;
      if (acked != null &&
          !acked.isCompleted &&
          ListenUdp.isAck(data, _session, _nonce!, _key)) {
        acked.complete(true);
        continue;
      }
      final fragment = ListenUdp.parseAudio(data, _session);
      if (fragment == null) continue;
      ++datagrams;
      final whole = _reassembler.add(fragment);
      if (whole == null || whole.packet.length < 56) continue;
      final sequence =
          ByteData.sublistView(whole.packet).getUint64(16, Endian.little);
      if (!whole.repeat) {
        _firstSeen.add(sequence);
        if (_firstSeen.length > 512) _firstSeen.remove(_firstSeen.first);
      } else if (!_firstSeen.contains(sequence)) {
        ++repeatsUsed;
        _firstSeen.add(sequence);
      }
      ++packets;
      lastAudioUs = nowUs;
      _onPacket(whole.packet, whole.repeat);
    }
  }

  /// Tells the laptop UDP still works (every 200 ms from the controller).
  void report(
      {required int highestSequence,
      required int lostPackets,
      required int bufferMs,
      required int concealedGaps}) {
    _sendTo(ListenUdp.report(
        _session,
        _key,
        ListenUdpReport(
            highestSequence: highestSequence,
            lostPackets: lostPackets,
            recoveredPackets: repeatsUsed,
            bufferMs: bufferMs,
            counter: ++_reportCounter,
            concealedGaps: concealedGaps)));
  }

  /// Microseconds since the last audio datagram (-1: none yet).
  int silentForUs() => lastAudioUs < 0 ? -1 : nowUs - lastAudioUs;

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.close();
  }
}
