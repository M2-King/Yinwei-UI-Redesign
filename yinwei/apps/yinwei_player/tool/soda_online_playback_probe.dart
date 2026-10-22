import 'dart:io';
import 'package:yinwei_player/remote/soda_online.dart';
import 'package:yinwei_player/remote/soda_track_launcher.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

/// Local, supervised one-song check. Never starts/stops Live or reads cookies.
/// Not imported by the app or reachable through a preview HTTP endpoint.
Future<void> main(List<String> args) async {
  if (!Platform.isWindows ||
      args.length != 1 ||
      args.single != '--supervised') {
    stderr.writeln(
        'Windows only. Run with --supervised while the owner is listening.');
    exitCode = 64;
    return;
  }
  stdout.writeln(
      'This brings 汽水 to the front and changes its queue. Live must already be running.');
  stdout.write('Search (at least two characters): ');
  final query = stdin.readLineSync();
  if (query == null) {
    return;
  }
  final temp = await Directory.systemTemp.createTemp('yinwei-soda-play-proof-');
  final service = SodaOnline(identityDirectory: temp, playbackVerified: true);
  try {
    final value = await service.browse('search', {'query': query});
    final rows = (value['rows'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < rows.length; i++) {
      stdout.writeln(
          '${i + 1}. ${rows[i]['title']} — ${rows[i]['artist']}${rows[i]['playable'] == true ? '' : ' (unavailable)'}');
    }
    stdout.write('Choose a song number, or Enter to cancel: ');
    final choice = int.tryParse(stdin.readLineSync() ?? '');
    if (choice == null || choice < 1 || choice > rows.length) {
      return;
    }
    stdout
        .write('Owner ready and listening? Type PLAY to submit exactly once: ');
    if (stdin.readLineSync() != 'PLAY') {
      return;
    }
    final selection = {
      'track': rows[choice - 1]['id'],
      'revision': value['revision']
    };
    final id = service.resolveTrack(selection);
    final timer = Stopwatch()..start();
    await SodaTrackLauncher().play(id, beforeDispatch: () {},
        revalidateSelection: () async {
      if (service.resolveTrack(selection) != id) {
        throw const RemoteFailure('soda_stale_selection');
      }
    });
    stdout.writeln(
        'Submitted once in ${timer.elapsedMilliseconds} ms. This is not confirmation of playback.');
    stdout.writeln(
        'Record chosen-song correctness, foreground/queue effects and iPad audible delay with the owner. No app feature flag was changed.');
  } on RemoteFailure catch (e) {
    stderr.writeln(e.code);
    exitCode = 1;
  } finally {
    service.close();
    await temp.delete(recursive: true);
  }
}
