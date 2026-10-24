// ignore_for_file: avoid_print
// Read-only local cache timing probe. Never launches music, changes playback,
// writes provider/persistent history files, or prints account/selection/song metadata.
import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/remote/listen_tap_trace.dart';
import 'package:yinwei_player/remote/soda_cache_reader.dart';
import 'package:yinwei_player/remote/soda_library.dart';

Future<void> main() async {
  final reader = SodaCacheReader();
  if (!reader.available) {
    print('TAP_CACHE_BENCH unavailable');
    return;
  }
  final clock = Stopwatch()..start();
  final reads = <int>[], accounts = <int>[];
  Directory? storage;
  try {
    for (var i = 0; i < 3; i++) {
      clock.reset();
      await reader.read();
      reads.add(clock.elapsedMicroseconds);
      clock.reset();
      await reader.readAccount();
      accounts.add(clock.elapsedMicroseconds);
    }
    storage = await Directory.systemTemp.createTemp('yinwei-tap-probe-');
    final library = SodaLibrary(reader: reader, storageDirectory: storage);
    final catalog = await library.browse({});
    final lists = catalog['lists'] as List;
    final list =
        lists.cast<Map>().where((l) => l['historical'] != true).firstOrNull;
    final resolves = <int>[];
    if (list != null) {
      final detail = await library.browse({'list': list['id']});
      final page = detail['page'] as Map?;
      final row = (page?['rows'] as List?)
          ?.cast<Map>()
          .where((r) => r['playable'] == true)
          .firstOrNull;
      if (row != null) {
        final payload = <String, dynamic>{
          'list': list['id'],
          'snapshot': page!['snapshot'],
          'track': row['id'],
          'revision': detail['revision']
        };
        ListenTapTrace.begin('probe.selection');
        for (var i = 0; i < 2; i++) {
          clock.reset();
          await library.resolveTrack(payload, revalidate: i == 1);
          resolves.add(clock.elapsedMicroseconds);
        }
      }
    }
    print('TAP_CACHE_BENCH ${jsonEncode({
          'fullReadUs': reads,
          'accountReadUs': accounts,
          'resolveUs': resolves,
          'trace': ListenTapTrace.snapshot()
        })}');
  } on SodaCacheFailure catch (e) {
    print('TAP_CACHE_BENCH ${e.code}');
  } on SodaLibraryFailure catch (e) {
    print('TAP_CACHE_BENCH ${e.code}');
  } finally {
    if (storage != null) await storage.delete(recursive: true);
  }
}
