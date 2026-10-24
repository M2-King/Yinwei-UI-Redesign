import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Listen audio over UDP (docs/IMPLEMENTATION_LISTEN_UDP_AUDIO.md): datagram
/// formats, signing, fragments and the packet orderer. Pure functions, no
/// sockets, so every rule is testable without a network.
///
/// The audio itself stays the unchanged 56-byte-header YNO1/YNW1 packet; UDP
/// only wraps it. UDP is used only inside the private Tailscale route.
class ListenUdp {
  static const helloMagic = 0x48554e59; // 'YNUH'
  static const ackMagic = 0x41554e59; // 'YNUA'
  static const audioMagic = 0x31554e59; // 'YNU1'
  static const reportMagic = 0x52554e59; // 'YNUR'
  static const version = 1;
  static const sessionBytes = 16, keyBytes = 32, nonceBytes = 16, macBytes = 32;
  static const audioHeaderBytes = 16;

  /// Tailscale's MTU is 1280; leave room for IP (40) and UDP (8) headers.
  static const maxPayloadBytes = 1200;
  static const maxFragments = 2;

  /// Audio flags: bit 7 = the repeat copy, bits 4-6 = fragment index,
  /// bits 0-3 = fragment count.
  static const repeatFlag = 0x80;

  /// The second copy of each packet goes out this long after the first, so
  /// a short burst of loss still leaves one copy.
  static const repeatDelay = Duration(milliseconds: 40);

  static Uint8List random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  static Uint8List _mac(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; ++i) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _signed(
      int magic, List<int> session, List<int> body, List<int> key) {
    final out = BytesBuilder(copy: false)
      ..add(_u32(magic))
      ..add([version, 0, 0, 0])
      ..add(session)
      ..add(body);
    final unsigned = out.toBytes();
    return Uint8List.fromList([...unsigned, ..._mac(key, unsigned)]);
  }

  /// Returns the body (between the session and the MAC) when the datagram
  /// has [magic], this version and [session], and its MAC verifies.
  static Uint8List? _verified(
      Uint8List data, int magic, List<int> session, List<int> key) {
    const head = 8 + sessionBytes;
    if (data.length < head + macBytes ||
        _readU32(data, 0) != magic ||
        data[4] != version ||
        !_same(data.sublist(8, head), session)) {
      return null;
    }
    final signedPart = data.sublist(0, data.length - macBytes);
    if (!_same(_mac(key, signedPart), data.sublist(data.length - macBytes))) {
      return null;
    }
    return data.sublist(head, data.length - macBytes);
  }

  static Uint8List hello(List<int> session, List<int> nonce, List<int> key) =>
      _signed(helloMagic, session, nonce, key);

  static Uint8List? helloNonce(
          Uint8List data, List<int> session, List<int> key) =>
      _length(_verified(data, helloMagic, session, key), nonceBytes);

  static Uint8List ack(List<int> session, List<int> nonce, List<int> key) =>
      _signed(ackMagic, session, nonce, key);

  static bool isAck(
      Uint8List data, List<int> session, List<int> nonce, List<int> key) {
    final body = _verified(data, ackMagic, session, key);
    return body != null && _same(body, nonce);
  }

  /// Receiver report: what arrived, so the laptop knows UDP still works.
  static Uint8List report(List<int> session, List<int> key, ListenUdpReport r) {
    final b = ByteData(28)
      ..setUint64(0, r.highestSequence, Endian.little)
      ..setUint32(8, r.lostPackets, Endian.little)
      ..setUint32(12, r.recoveredPackets, Endian.little)
      ..setUint32(16, r.bufferMs, Endian.little)
      ..setUint32(20, r.counter, Endian.little)
      ..setUint32(24, r.concealedGaps, Endian.little);
    return _signed(reportMagic, session, b.buffer.asUint8List(), key);
  }

  static ListenUdpReport? parseReport(
      Uint8List data, List<int> session, List<int> key) {
    final body = _length(_verified(data, reportMagic, session, key), 28);
    if (body == null) return null;
    final b = ByteData.sublistView(body);
    return ListenUdpReport(
        highestSequence: b.getUint64(0, Endian.little),
        lostPackets: b.getUint32(8, Endian.little),
        recoveredPackets: b.getUint32(12, Endian.little),
        bufferMs: b.getUint32(16, Endian.little),
        counter: b.getUint32(20, Endian.little),
        concealedGaps: b.getUint32(24, Endian.little));
  }

  /// Wraps one YNO1/YNW1 packet into 1-2 audio datagrams. All fragments of
  /// one send share [counter]; the repeat copy is sent with a new counter.
  /// Null when the packet needs more than [maxFragments] datagrams.
  static List<Uint8List>? audio(
      List<int> session, int counter, Uint8List packet,
      {bool repeat = false}) {
    final count = (packet.length + maxPayloadBytes - 1) ~/ maxPayloadBytes;
    if (count < 1 || count > maxFragments) return null;
    final size = (packet.length + count - 1) ~/ count;
    return [
      for (var i = 0; i < count; ++i)
        Uint8List.fromList([
          ..._u32(audioMagic),
          version,
          (repeat ? repeatFlag : 0) | (i << 4) | count,
          0,
          0,
          ..._u32(counter),
          ...session.take(4),
          ...packet.sublist(i * size, min(packet.length, (i + 1) * size)),
        ])
    ];
  }

  /// Splits an audio datagram; null when it is not ours.
  static ListenUdpFragment? parseAudio(Uint8List data, List<int> session) {
    if (data.length <= audioHeaderBytes ||
        _readU32(data, 0) != audioMagic ||
        data[4] != version ||
        !_same(data.sublist(12, 16), session.take(4).toList())) {
      return null;
    }
    final flags = data[5], count = flags & 0x0f, index = (flags >> 4) & 0x07;
    if (count < 1 || count > maxFragments || index >= count) return null;
    return ListenUdpFragment(
        counter: _readU32(data, 8),
        index: index,
        count: count,
        repeat: flags & repeatFlag != 0,
        payload: data.sublist(audioHeaderBytes));
  }

  static Uint8List? _length(Uint8List? data, int n) =>
      data != null && data.length == n ? data : null;
  static List<int> _u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  static int _readU32(Uint8List d, int o) =>
      ByteData.sublistView(d).getUint32(o, Endian.little);
}

/// Sends datagrams in order without losing them to a busy socket: on
/// Windows `RawDatagramSocket.send` often returns 0 ("not ready, nothing
/// sent") instead of failing; 685 of 800 sends in a burst did (2026-10-24).
/// Unsent datagrams wait for the socket's write event. At most [limit] wait:
/// older audio is worthless, so the oldest is dropped first.
class ListenUdpOutbox {
  ListenUdpOutbox(this.socket, {this.limit = 64});
  final RawDatagramSocket socket;
  final int limit;
  final _queue = <({Uint8List data, InternetAddress to, int port})>[];
  int sent = 0, dropped = 0;

  void send(Uint8List data, InternetAddress to, int port) {
    _queue.add((data: data, to: to, port: port));
    while (_queue.length > limit) {
      _queue.removeAt(0);
      ++dropped;
    }
    flush();
  }

  /// Sends what the socket accepts; call again on [RawSocketEvent.write].
  void flush() {
    while (_queue.isNotEmpty) {
      final item = _queue.first;
      int n;
      try {
        n = socket.send(item.data, item.to, item.port);
      } catch (_) {
        _queue.removeAt(0);
        ++dropped;
        continue;
      }
      if (n == 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _queue.removeAt(0);
      ++sent;
    }
  }

  void clear() => _queue.clear();
}

class ListenUdpReport {
  const ListenUdpReport(
      {required this.highestSequence,
      required this.lostPackets,
      required this.recoveredPackets,
      required this.bufferMs,
      required this.counter,
      this.concealedGaps = 0});
  final int highestSequence, lostPackets, recoveredPackets, bufferMs, counter;
  final int concealedGaps;
}

class ListenUdpFragment {
  const ListenUdpFragment(
      {required this.counter,
      required this.index,
      required this.count,
      required this.repeat,
      required this.payload});
  final int counter, index, count;
  final bool repeat;
  final Uint8List payload;
}

/// Joins fragments by counter. Keeps at most 8 incomplete sends.
class ListenUdpReassembler {
  final _parts = <int, List<Uint8List?>>{};

  /// The whole packet once every fragment of its send arrived.
  ({Uint8List packet, bool repeat})? add(ListenUdpFragment f) {
    if (f.count == 1) return (packet: f.payload, repeat: f.repeat);
    final parts = _parts.putIfAbsent(f.counter, () {
      if (_parts.length >= 8) _parts.remove(_parts.keys.first);
      return List<Uint8List?>.filled(f.count, null);
    });
    if (parts.length != f.count) return null;
    parts[f.index] = f.payload;
    if (parts.any((p) => p == null)) return null;
    _parts.remove(f.counter);
    return (
      packet: Uint8List.fromList([for (final p in parts) ...p!]),
      repeat: f.repeat
    );
  }
}

/// What the orderer hands on: a packet to play, or a gap of [frames] to
/// conceal before the next packet.
sealed class ListenOrdered {}

class ListenOrderedPacket extends ListenOrdered {
  ListenOrderedPacket(this.packet, this.sequence);
  final Uint8List packet;
  final int sequence;
}

class ListenOrderedGap extends ListenOrdered {
  ListenOrderedGap(this.frames);
  final int frames;
}

/// Puts packets from the WebSocket and/or UDP back in sequence order, drops
/// duplicates (each packet arrives twice over UDP), waits briefly for a late
/// one, then declares it lost.
///
/// Gaps are measured in frames from each packet's firstFrame, so they work
/// for 20 ms Opus and for variable PCM packets. A new epoch (seek, new song,
/// source change) restarts the timeline without a gap.
class ListenPacketOrderer {
  ListenPacketOrderer({this.wait = const Duration(milliseconds: 60)});

  /// How long a later packet waits for a missing earlier one. Longer than
  /// [ListenUdp.repeatDelay], so the repeat copy can still fill the hole.
  Duration wait;

  /// Gaps longer than this are not concealed (the stream jumped).
  static const maxGapFrames = 48000 ~/ 5; // 200 ms at 48 kHz

  int? _epoch, _next, _nextFrame;
  final _held = <int, ({Uint8List packet, int firstFrame, int frames})>{};
  int? _waitingSinceUs;
  int duplicates = 0, late = 0, lost = 0, concealedGaps = 0;
  int get highestSequence => _highest;
  int _highest = 0;

  void reset() {
    _epoch = _next = _nextFrame = _waitingSinceUs = null;
    _held.clear();
  }

  /// Adds one packet; returns what can be played now, in order.
  List<ListenOrdered> add(Uint8List packet, int nowUs) {
    final h = ByteData.sublistView(packet);
    if (packet.length < 56) return const [];
    final epoch = h.getUint64(8, Endian.little);
    final sequence = h.getUint64(16, Endian.little);
    final firstFrame = h.getUint64(24, Endian.little);
    final frames = h.getUint32(36, Endian.little);
    if (sequence > _highest) _highest = sequence;
    final out = <ListenOrdered>[];
    if (_epoch != null && epoch < _epoch!) {
      ++late;
      return out;
    }
    if (epoch != _epoch) {
      // Play what is held from the old epoch, then start the new timeline.
      if (_epoch != null) out.addAll(_flush());
      _epoch = epoch;
      _next = sequence;
      _nextFrame = null;
    }
    if (sequence < _next! || _held.containsKey(sequence)) {
      ++duplicates;
      return out;
    }
    _held[sequence] = (packet: packet, firstFrame: firstFrame, frames: frames);
    out.addAll(_drain());
    if (_held.isNotEmpty) _waitingSinceUs ??= nowUs;
    return out;
  }

  /// Called regularly: gives up on a missing packet once [wait] has passed.
  List<ListenOrdered> tick(int nowUs) {
    final since = _waitingSinceUs;
    if (since == null || _held.isEmpty) return const [];
    if (nowUs - since < wait.inMicroseconds) return const [];
    final first = _held.keys.reduce(min);
    lost += first - _next!;
    _next = first;
    _waitingSinceUs = null;
    final out = _drain();
    if (_held.isNotEmpty) _waitingSinceUs = nowUs;
    return out;
  }

  List<ListenOrdered> _drain() {
    final out = <ListenOrdered>[];
    while (true) {
      final item = _held.remove(_next);
      if (item == null) break;
      final expected = _nextFrame;
      if (expected != null && item.firstFrame > expected) {
        final gap = item.firstFrame - expected;
        if (gap <= maxGapFrames) {
          ++concealedGaps;
          out.add(ListenOrderedGap(gap));
        }
      }
      out.add(ListenOrderedPacket(item.packet, _next!));
      _nextFrame = item.firstFrame + item.frames;
      _next = _next! + 1;
      _waitingSinceUs = null;
    }
    return out;
  }

  List<ListenOrdered> _flush() {
    final out = <ListenOrdered>[];
    while (_held.isNotEmpty) {
      final first = _held.keys.reduce(min);
      _next = first;
      out.addAll(_drain());
    }
    _waitingSinceUs = null;
    return out;
  }
}
