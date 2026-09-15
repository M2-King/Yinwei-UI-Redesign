import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/system_media.dart';

void main() {
  test('Changing and Opened keep previous playing', () {
    expect(SystemMediaService.coercePlaying('Playing', false), isTrue);
    expect(SystemMediaService.coercePlaying('Changing', true), isTrue);
    expect(SystemMediaService.coercePlaying('Changing', false), isFalse);
    expect(SystemMediaService.coercePlaying('Opened', true), isTrue);
    expect(SystemMediaService.coercePlaying('Paused', true), isFalse);
    expect(SystemMediaService.coercePlaying('Stopped', true), isFalse);
  });

  test('sessionFresh ignores a brief no_session gap', () {
    final s = SystemMediaService();
    expect(s.sessionFresh, isFalse);
    s.lastActiveAt = DateTime.now();
    expect(s.sessionFresh, isTrue);
    s.lastActiveAt = DateTime.now().subtract(
      SystemMediaService.sessionStaleAfter + const Duration(milliseconds: 50),
    );
    expect(s.sessionFresh, isFalse);
  });

  test('no_session does not wipe; a new playing pid is applied', () {
    final s = SystemMediaService();
    s.applyDaemonLine(
      '{"status":"active","title":"U29uZw==","artist":"","album":"",'
      '"playbackStatus":"Playing","position":1,"duration":10,'
      '"source":"SodaMusic","pid":111,"process":"SodaMusic"}',
    );
    expect(s.state.pid, 111);
    expect(s.state.title, 'Song');
    expect(s.state.playing, isTrue);

    s.applyDaemonLine('{"status":"no_session"}');
    expect(s.state.pid, 111);
    expect(s.state.title, 'Song');

    s.applyDaemonLine(
      '{"status":"active","title":"T3RoZXI=","artist":"","album":"",'
      '"playbackStatus":"Playing","position":2,"duration":20,'
      '"source":"Spotify","pid":222,"process":"Spotify"}',
    );
    expect(s.state.pid, 222);
    expect(s.state.title, 'Other');
    expect(s.state.processName, 'Spotify');
    expect(s.state.playing, isTrue);
  });

  test('pid>0 is applied even when process name is empty', () {
    final s = SystemMediaService();
    s.applyDaemonLine(
      '{"status":"active","title":"U29uZw==","artist":"","album":"",'
      '"playbackStatus":"Playing","position":1,"duration":10,'
      '"source":"汽水音乐","pid":44592,"process":""}',
    );
    expect(s.state.pid, 44592);
    expect(s.state.processName, isEmpty);
    expect(s.state.title, 'Song');
    expect(s.state.hasTrack, isTrue);
  });

  test('汽水 display AUMID maps to SodaMusic.exe, not a browser', () {
    expect(SmtcLoopbackPicker.processPatternForAumid('汽水音乐'), 'SodaMusic');
    expect(SmtcLoopbackPicker.processPatternForAumid('SodaMusic'), 'SodaMusic');
    expect(SmtcLoopbackPicker.shouldScanAllMusicApps('汽水音乐'), isTrue);
    expect(SmtcLoopbackPicker.shouldScanAllMusicApps(''), isTrue);
    expect(SmtcLoopbackPicker.shouldScanAllMusicApps('SpotifyAB.SpotifyMusic'), isFalse);
    expect(SmtcLoopbackPicker.looksLikeBrowser('Chrome'), isTrue);
    expect(SmtcLoopbackPicker.looksLikeBrowser('汽水音乐'), isFalse);
    expect(SmtcLoopbackPicker.isExcludedProcess('yinwei_player'), isTrue);
    expect(SmtcLoopbackPicker.isExcludedProcess('SodaMusic.exe'), isFalse);
    expect(
      SmtcLoopbackPicker.musicProcessPatterns.contains('SodaMusic'),
      isTrue,
    );
  });
}

