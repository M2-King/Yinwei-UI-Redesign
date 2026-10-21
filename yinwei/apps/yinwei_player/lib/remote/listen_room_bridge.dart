import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/ios_laptop_listen_output.dart';

import 'laptop_listen_controller.dart';
import 'listen_quality.dart';

/// Connects the Listen Room page (`assets/listen_room/`) to the listening
/// session (IMPLEMENTATION_IPAD_LISTEN_ROOM.md §4).
///
/// - **State, app → page:** [state] turns the session and the laptop's
///   snapshot into the page's version-1 state. It is sent with
///   `YinweiListen.apply(...)` whenever the session changes, at most once per
///   [minInterval] (10 times a second), and only when something changed.
/// - **Intents, page → app:** [handle] validates each message from the page's
///   `YinweiNative` channel and calls the session, which uses the laptop's
///   existing commands and control-lease rules. A tap on a control takes
///   control first, unless the laptop has taken it (then the page shows
///   "Take control"). Numbers are clamped to the coordinator's ranges.
///
/// The session stays the only source of truth: the page draws what it gets.
/// The laptop protocol is unchanged, so the laptop's name is not known here
/// and the page says [laptopLabel].
class ListenRoomBridge {
  ListenRoomBridge({
    required this.session,
    required this.run,
    this.localPlayerPlaying,
    this.minInterval = const Duration(milliseconds: 100),
    this.laptopLabel = 'your laptop',
    this.canClose = true,
  });

  /// False when the room is the whole app: the page hides "Back to the
  /// player" and a close request is ignored.
  final bool canClose;

  /// The page's "Check for updates" (shown only when set).
  VoidCallback? onCheckUpdates;

  final LaptopListenController session;

  /// Runs a script in the page.
  final Future<void> Function(String script) run;

  /// The iPad's own file player is playing: listening waits for it.
  final bool Function()? localPlayerPlaying;
  final Duration minInterval;
  final String laptopLabel;

  /// The page drew its first frame (`ready`).
  VoidCallback? onReady;

  /// The page cannot run (`error`, e.g. no WebGL): show the classic screen.
  void Function(String reason)? onPageError;

  /// The page's "Back to the player" (`close`).
  VoidCallback? onClose;

  IosLaptopListenOutput? get _iosOutput =>
      session.output is IosLaptopListenOutput
          ? session.output as IosLaptopListenOutput
          : null;

  /// Local iPad gain (0–1), owned by the output across room lifetimes.
  double get volume => _iosOutput?.volume ?? _volume;
  double _volume = 1;

  /// Smoothed incoming stereo peak (0–1), before the local volume control.
  double get level =>
      session.listening && session.audioConnected && !session.interrupted
          ? _iosOutput?.level.value ?? 0
          : 0;

  /// Page points ([x, y, w, h]) equal Flutter logical pixels because the
  /// WebView fills this screen. Null removes the native picker.
  List<int>? get airplayRect => _airplayRect;
  List<int>? _airplayRect;
  VoidCallback? onAirplayRectChanged;

  void _setAirplayRect(List<int>? rect) {
    if (listEquals(_airplayRect, rect)) return;
    _airplayRect = rect;
    onAirplayRectChanged?.call();
  }

  bool _ready = false, _disposed = false, _seenConnected = false;
  // This iPad asked the laptop to start (music + Live): shown as progress
  // until the laptop reports its own step.
  bool _startingLive = false;
  int _musicGeneration = 0;
  bool _musicPlaying = false;

  /// The app is in the background: nothing is sent to the page. iPadOS
  /// freezes the hidden WebView, and each update would wait on the main
  /// thread, which also hands audio packets to the speaker.
  bool get background => _background;
  bool _background = false;
  set background(bool value) {
    _background = value;
    if (value) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Timer? _timer;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastJson;

  bool get ready => _ready;

  void attach() {
    session.addListener(_changed);
    _iosOutput?.level.addListener(schedule);
  }

  void dispose() {
    _disposed = true;
    _musicGeneration++;
    _timer?.cancel();
    session.removeListener(_changed);
    _iosOutput?.level.removeListener(schedule);
  }

  /// The page was reloaded (e.g. iPadOS ended its web process): wait for its
  /// next `ready`, then send the whole state again.
  void pageReloaded() {
    _ready = false;
    _lastJson = null;
    _setAirplayRect(null);
  }

  // ------------------------------------------------------------ state out

  /// The page state, version 1.
  Map<String, dynamic> state() {
    final s = session;
    final snap = s.snapshot ?? const <String, dynamic>{};
    final caps = _map(snap['capabilities']);
    final live = _map(snap['live']);
    final track = _map(snap['track']);
    final transport = _map(snap['transport']);
    final mode = _map(snap['spatialMode']);
    final array = _map(snap['arrayState']);
    // Older hosts can still draw their existing array, but cannot edit it.
    final visuals = _map(snap['presentation'])['arraySpeakers'];
    final speakers = array['speakers'] is List
        ? array['speakers'] as List
        : visuals is List && visuals.isNotEmpty
            ? [
                for (final raw in visuals)
                  if (raw is Map<String, dynamic>)
                    {
                      'index': raw['index'],
                      'label': raw['label'],
                      'az': raw['azimuthDeg'],
                      'el': raw['elevationDeg'],
                      'dist': raw['distanceM'],
                      'gainDb': raw['gainDb'] ?? 0,
                      'mute': raw['mute'] == true,
                      'feed': raw['index'] == 0
                          ? 'left'
                          : raw['index'] == 1
                              ? 'right'
                              : 'mid',
                    }
              ]
            : [
                for (var i = 0; i < 2; i++)
                  {
                    'index': i,
                    'label': i == 0 ? 'L' : 'R',
                    'az': i == 0 ? -30 : 30,
                    'el': 0,
                    'dist': 1.8,
                    'gainDb': 0,
                    'mute': false,
                    'feed': i == 0 ? 'left' : 'right',
                  }
              ];
    final pose = _map(snap['pose']);
    final liveRunning = snap['liveRunning'] == true;
    final source = _text(live['source']);
    // No music app open: the one the laptop opens on "Start on laptop".
    final opens = !liveRunning && source.isEmpty && caps['remoteLive'] == true
        ? _text(live['openApp'])
        : '';
    final title = liveRunning ? _text(live['title']) : _text(track['title']);
    // Orbit: where the sound is now (the laptop's Live engine, or the file
    // player's heading), so the room's light follows the sound instead of
    // being pulled back to the start direction.
    final orbiting = mode['array'] != 'stereo2' && mode['motion'] == 'orbit';
    final heading = !orbiting
        ? null
        : liveRunning
            ? _num(live['azimuthDeg'])
            : transport['playing'] == true
                ? _num(_map(snap['telemetry'])['azimuthDeg'])
                : null;
    // Song progress (seconds): the music app's over Live, else the file's.
    final hasFile = track['hasFile'] == true;
    final pos = liveRunning
        ? _num(live['positionSec']) ?? 0
        : hasFile
            ? (_num(transport['positionMs']) ?? 0) / 1000
            : 0.0;
    final dur = liveRunning
        ? _num(live['durationSec']) ?? 0
        : hasFile
            ? (_num(track['durationMs']) ?? 0) / 1000
            : 0.0;
    final seekable = dur > 0 && (!liveRunning || caps['liveSeek'] == true);
    // Start progress: the laptop's step while it starts, else this iPad's.
    final stage = _text(live['startStage']);
    final progress = stage.isNotEmpty
        ? stage
        : _startingLive && !liveRunning
            ? 'asking'
            : s.listening && !s.audioConnected
                ? 'audio'
                : null;
    final playing =
        liveRunning ? live['playing'] == true : transport['playing'] == true;
    if (s.connected) _seenConnected = true;
    if (!s.signedIn) _seenConnected = false;
    final lost = _seenConnected && !s.connected;
    final other = !s.hasControl && (snap['controlHeld'] == true || _takenAway);
    return {
      'v': 1,
      'laptop': laptopLabel,
      'connection': lost ? 'reconnecting' : 'connected',
      'source': source.isNotEmpty
          ? source
          : liveRunning
              ? 'your music app'
              : 'the Yinwei player',
      'live': liveRunning,
      'playing': playing,
      'listening':
          s.listening ? (s.audioConnected ? 'on' : 'connecting') : 'off',
      'control': other ? 'other' : 'mine',
      'notice': lost
          ? 'lost'
          : s.interrupted
              ? 'interrupted'
              : s.listening && s.status.startsWith(_audioBusyStatus)
                  ? 'busy'
                  : _noMusicApp(snap, caps, liveRunning, source, opens)
                      ? 'noapp'
                      : 'none',
      'mode': mode['array'] == 'stereo2' ? 'stereo2' : 'point',
      'speakers': speakers,
      'selectedSpeakerIndex': array['selectedIndex'] ?? 0,
      'arrayRevision': array['revision'] ?? 0,
      'maxSpeakers': array['maxSpeakers'] ?? 8,
      'speakerControl': caps['remoteSpeakers'] == true,
      'matrixLinked': array['matrixLinked'] == true,
      'matrixSpread': array['matrixSpread'] ?? 1.0,
      'motion': mode['motion'] == 'orbit' ? 'orbit' : 'fixed',
      'orbitHz': _num(mode['orbitHz'])?.clamp(0.05, 2.0) ?? 0.4,
      'az': heading != null
          ? _wrapDeg(heading)
          : _num(pose['azimuthDeg'])?.clamp(-180.0, 180.0) ?? 0,
      'el': _num(pose['elevationDeg'])?.clamp(-90.0, 90.0) ?? 0,
      'dist': _num(pose['distanceM'])?.clamp(0.5, 10.0) ?? 2,
      'track': title.isEmpty
          ? null
          : {
              'title': title,
              'artist': liveRunning ? '' : _text(track['artist']),
            },
      'volume': volume,
      'level': level,
      'opens': opens.isEmpty ? null : opens,
      // A command is on its way: the page keeps what you tapped until then.
      'pending': s.pending,
      'canClose': canClose,
      'updates': onCheckUpdates != null,
      'quality': s.soundQuality.name,
      'stream': s.audioConnected ? s.streamQuality?.name : null,
      'opus': s.opusAvailable,
      'music': s.signedIn && caps['sodaLibrary'] == true,
      'progress': progress,
      'pos': dur > 0 ? pos.clamp(0.0, dur) : 0,
      'dur': dur > 0 ? dur : 0,
      'seekable': seekable,
      'stats': {
        'received': s.received,
        'bufferMs': s.bufferMs,
        'underruns': s.underruns,
      },
    };
  }

  /// How the controller words "Safari (or another device) is listening".
  static const _audioBusyStatus = 'Another device is listening';

  bool get _takenAway =>
      session.notice == LaptopListenController.failureText('control_taken') ||
      session.notice == LaptopListenController.failureText('control_busy');

  /// Only while the laptop reports no music app: once one opens there, a
  /// failed start's note no longer blocks the button.
  bool _noMusicApp(Map<String, dynamic> snap, Map<String, dynamic> caps,
          bool liveRunning, String source, String opens) =>
      !liveRunning &&
      source.isEmpty &&
      (session.notice == LaptopListenController.failureText('no_music_app') ||
          (opens.isEmpty &&
              caps['remoteLive'] == true &&
              _map(snap['track'])['hasFile'] != true));

  void _changed() => schedule();

  /// Sends the state soon: at once, or when [minInterval] has passed since
  /// the last send.
  void schedule() {
    if (!_ready || _disposed || _background || _timer != null) return;
    final wait = minInterval - DateTime.now().difference(_lastPush);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _timer = null;
      unawaited(push());
    });
  }

  /// Sends the state now, if it changed (or always, with [force]).
  Future<void> push({bool force = false}) async {
    if (!_ready || _disposed || _background) return;
    final json = jsonEncode(state());
    if (!force && json == _lastJson) return;
    _lastJson = json;
    _lastPush = DateTime.now();
    await run('YinweiListen.apply($json)');
  }

  Future<void> toast(String text) async {
    if (!_ready || _disposed || _background) return;
    await run('YinweiListen.toast(${jsonEncode(text)})');
  }

  // ------------------------------------------------------------ intents in

  /// One message from the page.
  Future<void> handle(String raw) async {
    if (_disposed) return;
    Map<String, dynamic> m;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic> || data['t'] is! String) return;
      m = data;
    } catch (_) {
      return;
    }
    final snap = session.snapshot ?? const <String, dynamic>{};
    final caps = _map(snap['capabilities']);
    switch (m['t']) {
      case 'ready':
        _ready = true;
        _lastJson = null;
        await push(force: true);
        onReady?.call();
      case 'error':
        onPageError?.call(_text(m['msg']));
      case 'close':
        if (canClose) onClose?.call();
      case 'quality':
        final quality = ListenQuality.parse(m['quality']);
        if (quality != null) session.setSoundQuality(quality);
      case 'checkUpdates':
        onCheckUpdates?.call();
      case 'copyAudioDiagnostics':
        try {
          await Clipboard.setData(ClipboardData(
              text: const JsonEncoder.withIndent('  ')
                  .convert(session.audioDiagnostics())));
          await toast('Audio diagnostics copied');
        } catch (_) {
          await toast('Could not copy audio diagnostics');
        }
      case 'musicClose':
        _musicGeneration++;
      case 'musicBrowse':
        if (caps['sodaLibrary'] != true || !session.signedIn) return;
        final requestId = m['request'];
        if (requestId is! int || requestId < 0 || requestId > 1000000000) {
          return;
        }
        final request = <String, dynamic>{};
        for (final key in ['list', 'snapshot']) {
          final value = m[key];
          if (value != null) {
            if (value is! String || value.length > 160 || value.isEmpty) return;
            request[key] = value;
          }
        }
        final offset = m['offset'];
        if (offset != null) {
          if (offset is! int || offset < 0 || offset > 100000) return;
          request['offset'] = offset;
        }
        final generation = ++_musicGeneration;
        final host = snap['hostSessionId'];
        Map<String, dynamic> value;
        try {
          value = await session.browseSoda(request);
        } catch (_) {
          value = {
            'error':
                'Cached music is unavailable. Open 汽水 on the laptop, then reopen Music.'
          };
        }
        if (_disposed ||
            _background ||
            generation != _musicGeneration ||
            !session.signedIn ||
            host != session.snapshot?['hostSessionId']) {
          return;
        }
        await run('YinweiListen.music(${jsonEncode({
              'request': requestId,
              ...value
            })})');
      case 'musicPlay':
        if (caps['sodaLibrary'] != true || _musicPlaying || session.pending) {
          return;
        }
        final payload = <String, dynamic>{};
        for (final key in ['list', 'snapshot', 'track', 'revision']) {
          final value = m[key];
          if (value is! String || value.isEmpty || value.length > 160) return;
          payload[key] = value;
        }
        _musicPlaying = true;
        try {
          await _command('library.play', payload);
        } finally {
          _musicPlaying = false;
        }
      case 'rects':
        final r = m['airplay'];
        final valid = r is List &&
            r.length == 4 &&
            r.every((v) => v is num && v.isFinite && v >= 0 && v <= 100000) &&
            (r[2] as num) >= 1 &&
            (r[3] as num) >= 1;
        _setAirplayRect(valid ? [for (final v in r) (v as num).round()] : null);
      case 'volume':
        final v = _num(m['v']);
        if (v == null) return;
        try {
          final next = v.clamp(0.0, 1.0).toDouble();
          await _iosOutput?.setVolume(next);
          _volume = next;
        } catch (_) {
          await toast('Could not change the iPad volume');
          await push(force: true);
        }
        schedule();
      case 'listen':
        if (localPlayerPlaying?.call() == true) {
          await toast('Pause the iPad’s own player first');
          await push(force: true);
          return;
        }
        final startLive = m['startLive'] == true &&
            caps['remoteLive'] == true &&
            snap['liveRunning'] != true;
        try {
          if (startLive) _starting(true);
          await session.startListening(startLive: startLive);
        } finally {
          if (startLive) _starting(false);
        }
        final notice = session.notice;
        if (notice != null) await toast(_toastText(notice));
      case 'stopListening':
        await session.stopListening();
      case 'take':
        final ok = await session.takeControl();
        await toast(ok
            ? 'You’re in control'
            : _toastText(session.notice ?? 'The laptop did not answer'));
        if (!ok) await push(force: true);
      case 'media':
        session.recordPageTap(m['tapMs']);
        final liveRunning = snap['liveRunning'] == true;
        final liveMedia = caps['liveMedia'] == true;
        final type = switch (m['a']) {
          // Not live yet: play starts the music and Live Transfer on the laptop.
          'play' when !liveRunning && caps['remoteLive'] == true =>
            'live.start',
          'play' => liveMedia ? 'media.play' : 'play',
          'pause' => liveMedia ? 'media.pause' : 'pause',
          'next' when liveMedia => 'media.next',
          'prev' when liveMedia => 'media.previous',
          _ => null,
        };
        if (type == null) {
          await toast('The laptop’s music app can’t change songs from here.');
          await push(force: true);
          return;
        }
        try {
          if (type == 'live.start') _starting(true);
          await _command(type);
        } finally {
          if (type == 'live.start') _starting(false);
        }
      case 'liveStop':
        await _command('live.stop');
      case 'layout':
        final mode = m['mode'];
        if ((mode == 'point' || mode == 'stereo2') &&
            caps['remoteArray'] == true) {
          await _command('array.mode', {'mode': mode});
        } else {
          await push(force: true);
        }
      case 'motion':
        final motion = m['motion'];
        if (motion != 'fixed' && motion != 'orbit') return;
        final hz = (_num(m['orbitHz']) ?? 0.4).clamp(0.05, 2.0);
        await _command('motion.set',
            {'motion': motion, if (motion == 'orbit') 'orbitHz': hz});
      case 'seek':
        final sec = _num(m['sec']);
        if (sec == null || sec < 0) return;
        if (snap['liveRunning'] == true) {
          if (caps['liveSeek'] != true) {
            await toast('This laptop can’t jump within the song yet.');
            await push(force: true);
            return;
          }
          await _command('media.seek', {'positionSec': sec});
        } else {
          await _command('seek', {'positionMs': (sec * 1000).round()});
        }
      case 'place':
        final az = _num(m['az']), el = _num(m['el']), dist = _num(m['dist']);
        if (az == null || el == null || dist == null) return;
        if (caps['pointControl'] != true) {
          await toast('The sound can’t be placed while 2.0 is on.');
          await push(force: true);
          return;
        }
        await _command('point.set', {
          'azimuthDeg': az.clamp(-180.0, 180.0),
          'elevationDeg': el.clamp(-90.0, 90.0),
          'distanceM': dist.clamp(0.5, 10.0),
        });
      case 'speakerAdd':
      case 'speakerRemove':
      case 'speakerSelect':
      case 'speakerPlace':
      case 'matrixLink':
      case 'matrixAdjust':
        final revision = m['arrayRevision'];
        final index = m['index'];
        if (caps['remoteSpeakers'] != true ||
            revision is! int ||
            revision < 0) {
          await push(force: true);
          return;
        }
        final type = switch (m['t']) {
          'speakerAdd' => 'array.speaker.add',
          'speakerRemove' => 'array.speaker.remove',
          'speakerSelect' => 'array.speaker.select',
          'matrixLink' => 'array.matrix.link',
          'matrixAdjust' => 'array.matrix.set',
          _ => 'array.speaker.set',
        };
        final needsIndex = m['t'] != 'speakerAdd' && m['t'] != 'matrixLink';
        if (needsIndex && (index is! int || index < 0 || index >= 8)) {
          return;
        }
        final payload = <String, dynamic>{
          'arrayRevision': revision,
          if (needsIndex) 'index': index,
        };
        if (m['t'] == 'matrixLink') {
          if (m['linked'] is! bool) return;
          payload['linked'] = m['linked'];
        }
        if (m['t'] == 'matrixAdjust') {
          final axis = m['axis'];
          final value = _num(m['value']);
          if (value == null || !['az', 'el', 'dist'].contains(axis)) return;
          final min = axis == 'dist'
              ? 0.5
              : axis == 'el'
                  ? -90.0
                  : -180.0;
          final max = axis == 'dist'
              ? 10.0
              : axis == 'el'
                  ? 90.0
                  : 180.0;
          if (value < min || value > max) return;
          payload.addAll({'axis': axis, 'value': value});
        }
        if (m['t'] == 'speakerPlace') {
          final az = _num(m['az']), el = _num(m['el']), dist = _num(m['dist']);
          if (az == null || el == null || dist == null) return;
          payload.addAll({
            'az': az.clamp(-180.0, 180.0),
            'el': el.clamp(-90.0, 90.0),
            'dist': dist.clamp(0.5, 10.0)
          });
        }
        // Keep the page's original revision through lease renewal/retry.
        await _command(type, payload);
      case 'signOut':
        await session.signOut();
      default:
        return; // `airplay` (browser only) and anything unknown
    }
  }

  /// A laptop command on the person's behalf: takes control first unless the
  /// laptop has taken it, waits for a command still in flight, then reports
  /// the result as a toast. A refusal re-sends the state, so the page's value
  /// gives way to the laptop's at once.
  Future<bool> _command(String type,
      [Map<String, dynamic> payload = const {}]) async {
    if (!session.hasControl) {
      if (_takenAway || !await session.takeControl()) {
        await toast(_toastText(session.notice ??
            'Someone at the laptop took control. Tap Take control to change things here.'));
        await push(force: true);
        return false;
      }
    }
    for (var i = 0; session.pending && i < 30; ++i) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final ok = await session.command(type, payload);
    final notice = session.notice;
    if (notice != null) await toast(_toastText(notice));
    if (!ok) await push(force: true);
    return ok;
  }

  // Toasts are short lines without a final full stop.
  void _starting(bool value) {
    _startingLive = value;
    schedule();
  }

  static double _wrapDeg(double a) {
    final w = ((a + 180) % 360 + 360) % 360 - 180;
    return w == -180 ? 180 : w;
  }

  static String _toastText(String text) =>
      text.endsWith('.') ? text.substring(0, text.length - 1) : text;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
  static String _text(Object? value) => value is String ? value.trim() : '';
  static double? _num(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;
}
