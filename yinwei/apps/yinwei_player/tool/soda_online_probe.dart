import 'dart:convert';
import 'dart:io';
import 'package:yinwei_player/remote/soda_online.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

/// Two bounded anonymous metadata reads; no app launch, audio, account or cookies.
Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('yinwei-soda-protocol-');
  final service = SodaOnline(identityDirectory: temp);
  try {
    for (final kind in ['search', 'modes']) {
      final watch = Stopwatch()..start();
      final value =
          await service.browse(kind, kind == 'search' ? {'query': '晴天'} : {});
      stdout.writeln(jsonEncode({
        'kind': kind,
        'rows': (value['rows'] as List).length,
        'modes': (value['modes'] as List).length,
        'elapsedMs': watch.elapsedMilliseconds,
        'playbackReady': value['playbackReady']
      }));
    }
  } on RemoteFailure catch (e) {
    stderr.writeln(e.code);
    exitCode = 1;
  } finally {
    service.close();
    await temp.delete(recursive: true);
  }
}
