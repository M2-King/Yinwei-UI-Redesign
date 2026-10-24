import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_udp_protocol.dart';

/// A YNO1-shaped packet: 56-byte header + [payload] bytes.
Uint8List packet(int sequence,
    {int epoch = 1, int? firstFrame, int frames = 960, int payload = 700}) {
  final p = Uint8List(56 + payload);
  ByteData.sublistView(p)
    ..setUint32(0, 0x314f4e59, Endian.little)
    ..setUint32(4, 1, Endian.little)
    ..setUint64(8, epoch, Endian.little)
    ..setUint64(16, sequence, Endian.little)
    ..setUint64(24, firstFrame ?? sequence * 960, Endian.little)
    ..setUint32(32, 48000, Endian.little)
    ..setUint32(36, frames, Endian.little);
  for (var i = 56; i < p.length; ++i) {
    p[i] = (sequence + i) & 0xff;
  }
  return p;
}

int seqOf(ListenOrdered o) => (o as ListenOrderedPacket).sequence;

void main() {
  final session = ListenUdp.random(ListenUdp.sessionBytes);
  final key = ListenUdp.random(ListenUdp.keyBytes);

  group('signing', () {
    test('hello and ack verify only with the session key', () {
      final nonce = ListenUdp.random(ListenUdp.nonceBytes);
      final hello = ListenUdp.hello(session, nonce, key);
      expect(ListenUdp.helloNonce(hello, session, key), nonce);
      expect(ListenUdp.helloNonce(hello, session, ListenUdp.random(32)), isNull);
      expect(ListenUdp.helloNonce(hello, ListenUdp.random(16), key), isNull);
      final tampered = Uint8List.fromList(hello)..[30] ^= 1;
      expect(ListenUdp.helloNonce(tampered, session, key), isNull);
      final ack = ListenUdp.ack(session, nonce, key);
      expect(ListenUdp.isAck(ack, session, nonce, key), isTrue);
      expect(ListenUdp.isAck(ack, session, ListenUdp.random(16), key), isFalse);
      expect(ListenUdp.isAck(hello, session, nonce, key), isFalse,
          reason: 'a hello is not an ack');
    });

    test('reports round-trip and reject a wrong key', () {
      const r = ListenUdpReport(
          highestSequence: 123456789,
          lostPackets: 3,
          recoveredPackets: 9,
          bufferMs: 140,
          counter: 7,
          concealedGaps: 2);
      final data = ListenUdp.report(session, key, r);
      final back = ListenUdp.parseReport(data, session, key)!;
      expect(back.highestSequence, 123456789);
      expect(back.lostPackets, 3);
      expect(back.recoveredPackets, 9);
      expect(back.bufferMs, 140);
      expect(back.counter, 7);
      expect(back.concealedGaps, 2);
      expect(ListenUdp.parseReport(data, session, ListenUdp.random(32)), isNull);
    });
  });

  group('audio datagrams', () {
    test('High (one datagram) fits the Tailscale MTU', () {
      final p = packet(1, payload: 800);
      final d = ListenUdp.audio(session, 5, p)!;
      expect(d, hasLength(1));
      expect(d.single.length, lessThanOrEqualTo(1250));
      final f = ListenUdp.parseAudio(d.single, session)!;
      expect(f.counter, 5);
      expect(f.repeat, isFalse);
      expect(f.payload, p);
    });

    test('Max (1275-byte Opus) splits into two and reassembles', () {
      final p = packet(2, payload: 1275);
      final d = ListenUdp.audio(session, 9, p, repeat: true)!;
      expect(d, hasLength(2));
      for (final x in d) {
        expect(x.length, lessThanOrEqualTo(1250));
      }
      final r = ListenUdpReassembler();
      expect(r.add(ListenUdp.parseAudio(d[1], session)!), isNull);
      final whole = r.add(ListenUdp.parseAudio(d[0], session)!)!;
      expect(whole.packet, p);
      expect(whole.repeat, isTrue);
    });

    test('lossless PCM (4 KB) is refused, it stays on the WebSocket', () {
      expect(ListenUdp.audio(session, 1, packet(1, payload: 4096)), isNull);
    });

    test('foreign datagrams are ignored', () {
      final d = ListenUdp.audio(session, 1, packet(1))!.single;
      expect(ListenUdp.parseAudio(d, ListenUdp.random(16)), isNull);
      expect(ListenUdp.parseAudio(Uint8List(10), session), isNull);
    });
  });

  group('orderer', () {
    test('in order passes straight through', () {
      final o = ListenPacketOrderer();
      final out = [for (var s = 1; s <= 5; ++s) ...o.add(packet(s), s * 20000)];
      expect(out.map(seqOf), [1, 2, 3, 4, 5]);
    });

    test('each packet twice: duplicates dropped', () {
      final o = ListenPacketOrderer();
      final out = <ListenOrdered>[];
      for (var s = 1; s <= 5; ++s) {
        out.addAll(o.add(packet(s), s * 20000));
        if (s > 2) out.addAll(o.add(packet(s - 2), s * 20000)); // repeat copy
      }
      expect(out.map(seqOf), [1, 2, 3, 4, 5]);
      expect(o.duplicates, 3);
    });

    test('reordered packet waits, then plays in order', () {
      final o = ListenPacketOrderer();
      expect(o.add(packet(1), 0).map(seqOf), [1]);
      expect(o.add(packet(3), 40000), isEmpty);
      expect(o.add(packet(2), 50000).map(seqOf), [2, 3]);
      expect(o.lost, 0);
    });

    test('a lost packet becomes one 20 ms gap after the wait', () {
      final o = ListenPacketOrderer(wait: const Duration(milliseconds: 60));
      o.add(packet(1), 0);
      expect(o.add(packet(3), 40000), isEmpty);
      expect(o.tick(90000), isEmpty, reason: 'still within the wait');
      final out = o.tick(100001);
      expect(out.first, isA<ListenOrderedGap>());
      expect((out.first as ListenOrderedGap).frames, 960);
      expect(seqOf(out[1]), 3);
      expect(o.lost, 1);
      expect(o.add(packet(2), 120000), isEmpty, reason: 'too late, dropped');
    });

    test('laptop-side drop (same sequence run, frames jump) is concealed', () {
      final o = ListenPacketOrderer();
      o.add(packet(1, firstFrame: 0), 0);
      final out = o.add(packet(2, firstFrame: 960 + 480), 20000);
      expect((out.first as ListenOrderedGap).frames, 480);
      expect(seqOf(out[1]), 2);
    });

    test('a new epoch restarts without a gap', () {
      final o = ListenPacketOrderer();
      o.add(packet(1, epoch: 1), 0);
      final out = o.add(packet(2, epoch: 2, firstFrame: 0), 20000);
      expect(out.map(seqOf), [2]);
      expect(o.add(packet(1, epoch: 1), 30000), isEmpty, reason: 'old epoch');
    });

    test('a jump longer than 200 ms is not filled', () {
      final o = ListenPacketOrderer();
      o.add(packet(1, firstFrame: 0), 0);
      final out = o.add(packet(2, firstFrame: 960 + 48000), 20000);
      expect(out.map(seqOf), [2]);
    });
  });
}
