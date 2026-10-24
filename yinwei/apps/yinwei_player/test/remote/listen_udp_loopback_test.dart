// Laptop sender ↔ lossy relay ↔ iPad receiver over real UDP on 127.0.0.1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_udp_protocol.dart';
import 'package:yinwei_player/remote/listen_udp_receiver.dart';
import 'package:yinwei_player/remote/listen_udp_sender.dart';

import 'listen_udp_protocol_test.dart' show packet;

/// Forwards datagrams both ways and drops audio with [loss] (seeded).
class LossyRelay {
  LossyRelay._(this.socket, this.laptopPort, this.loss, this.random)
      : out = ListenUdpOutbox(socket, limit: 256) {
    socket.listen((e) {
      if (e == RawSocketEvent.write) out.flush();
      if (e != RawSocketEvent.read) return;
      while (true) {
        final d = socket.receive();
        if (d == null) return;
        final fromLaptop = d.port == laptopPort;
        if (!fromLaptop) ipadPort = d.port;
        final audio = d.data.length > 4 &&
            ByteData.sublistView(d.data).getUint32(0, Endian.little) ==
                ListenUdp.audioMagic;
        if (audio && random.nextDouble() < loss) {
          ++dropped;
          continue;
        }
        final to = fromLaptop ? ipadPort : laptopPort;
        if (to != null) out.send(d.data, InternetAddress.loopbackIPv4, to);
      }
    });
  }
  static Future<LossyRelay> start(int laptopPort, double loss, int seed) async =>
      LossyRelay._(
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
          laptopPort,
          loss,
          Random(seed));
  final RawDatagramSocket socket;
  final ListenUdpOutbox out;
  final int laptopPort;
  double loss;
  final Random random;
  int? ipadPort;
  int dropped = 0;
}

Future<({int played, int gaps, int lost, int repeatsUsed})> run(
    double loss, int seed) async {
  final sender = (await ListenUdpSender.bind(InternetAddress.loopbackIPv4, 0))!;
  final relay = await LossyRelay.start(sender.port, loss, seed);
  final offer = sender.offer(InternetAddress.loopbackIPv4);
  final orderer = ListenPacketOrderer();
  final out = <ListenOrdered>[];
  final clock = Stopwatch()..start();
  final receiver = (await ListenUdpReceiver.connect(
      laptop: InternetAddress.loopbackIPv4,
      port: relay.socket.port,
      session: base64Decode(offer['session'] as String),
      key: base64Decode(offer['key'] as String),
      onPacket: (p, _) => out.addAll(orderer.add(p, clock.elapsedMicroseconds))))!;
  expect(sender.active, isTrue);
  // 400 packets = 8 s of audio, sent at 4x real time; repeats 40 ms later.
  var mediaUs = 0;
  for (var s = 1; s <= 400; ++s) {
    expect(sender.send(packet(s, payload: 800), mediaUs), isTrue);
    sender.tick(mediaUs);
    mediaUs += 20000;
    if (s % 4 == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      out.addAll(orderer.tick(clock.elapsedMicroseconds));
    }
  }
  sender.tick(mediaUs + 100000);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  out.addAll(orderer.tick(clock.elapsedMicroseconds + 1000000));
  receiver.report(
      highestSequence: orderer.highestSequence,
      lostPackets: orderer.lost,
      bufferMs: 120,
      concealedGaps: orderer.concealedGaps);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  expect(sender.lastReport?.highestSequence, orderer.highestSequence);
  receiver.close();
  sender.close();
  relay.socket.close();
  final played = out.whereType<ListenOrderedPacket>().map((p) => p.sequence);
  expect(played.toList(), List.of(played)..sort(), reason: 'always in order');
  expect(played.toSet().length, played.length, reason: 'no duplicates');
  return (
    played: played.length,
    gaps: out.whereType<ListenOrderedGap>().length,
    lost: orderer.lost,
    repeatsUsed: receiver.repeatsUsed
  );
}

void main() {
  test('no loss: every packet plays once, in order', () async {
    final r = await run(0, 1);
    expect(r.played, 400);
    expect(r.gaps, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  for (final loss in [0.01, 0.05, 0.10]) {
    test('${(loss * 100).round()} % random loss: repeats fill the holes', () async {
      final r = await run(loss, 42);
      // ignore: avoid_print
      print('UDP_LOSS ${(loss * 100).round()}% played=${r.played} '
          'repeatsUsed=${r.repeatsUsed} unrecovered=${400 - r.played} gaps=${r.gaps}');
      // Both copies lost has probability loss², so the unrecovered count
      // stays near 400 * loss² and every one becomes exactly one gap.
      expect(400 - r.played, lessThanOrEqualTo((400 * loss * loss * 4).ceil() + 1));
      expect(r.gaps, 400 - r.played);
      expect(r.repeatsUsed, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('a hello with the wrong key is not accepted', () async {
    final sender = (await ListenUdpSender.bind(InternetAddress.loopbackIPv4, 0))!;
    final offer = sender.offer(InternetAddress.loopbackIPv4);
    final receiver = await ListenUdpReceiver.connect(
        laptop: InternetAddress.loopbackIPv4,
        port: sender.port,
        session: base64Decode(offer['session'] as String),
        key: ListenUdp.random(32),
        onPacket: (_, __) {});
    expect(receiver, isNull);
    expect(sender.active, isFalse);
    sender.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('reports stop: the sender turns unhealthy after 3 s', () async {
    final sender = (await ListenUdpSender.bind(InternetAddress.loopbackIPv4, 0))!;
    final offer = sender.offer(InternetAddress.loopbackIPv4);
    final receiver = (await ListenUdpReceiver.connect(
        laptop: InternetAddress.loopbackIPv4,
        port: sender.port,
        session: base64Decode(offer['session'] as String),
        key: base64Decode(offer['key'] as String),
        onPacket: (_, __) {}))!;
    expect(sender.healthy(), isTrue);
    expect(sender.healthy(sender.nowUs + 3100000), isFalse);
    receiver.close();
    sender.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
