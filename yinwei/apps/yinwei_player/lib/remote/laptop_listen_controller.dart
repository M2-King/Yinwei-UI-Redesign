import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'remote_entry.dart';
import 'remote_owner_client.dart';

/// Plays the laptop's processed stereo on this device: the iPad's native
/// player in the app, a fake in tests.
abstract class LaptopListenOutput {
  /// Opens the output for listening. It holds the audio session (needed for
  /// lock-screen controls) and keeps playing in the background and while
  /// the screen is locked.
  Future<void> prepare();

  /// The laptop started a new stream (new epoch or sample rate): drop queued
  /// audio and play [sampleRate] from now on.
  Future<void> newStream(int sampleRate);

  /// Queues one YNW1 packet; false when it was dropped.
  Future<bool> write(Uint8List packet);

  /// `ready`, `interrupted`, `played`, `underruns`, `bufferMs`, `queuedMs`.
  Future<Map<String, dynamic>> status();

  Future<void> stop();

  /// What the lock screen and Control Center show.
  Future<void> showNowPlaying(
      {required String title, required String artist, required bool playing});
  Future<void> hideNowPlaying();

  /// Lock-screen and Control Center buttons (`play`, `pause`, `toggle`,
  /// `next`, `previous`); null removes them.
  void setRemoteCommandHandler(void Function(String action)? handler);
}

/// The header fields of one laptop audio packet (YNW1).
class YnwPacketHeader {
  const YnwPacketHeader(this.epoch, this.sequence, this.sampleRate);
  final int epoch, sequence, sampleRate;

  static YnwPacketHeader? parse(Uint8List packet) {
    if (packet.length < 64 || packet.length > 56 + 512 * 8) return null;
    final data = ByteData.sublistView(packet);
    final frames = data.getUint32(36, Endian.little);
    final rate = data.getUint32(32, Endian.little);
    if (data.getUint32(0, Endian.little) != 0x31574e59 ||
        data.getUint32(4, Endian.little) != 1 ||
        frames == 0 ||
        frames > 512 ||
        packet.length != 56 + frames * 8 ||
        rate < 8000 ||
        rate > 192000) {
      return null;
    }
    return YnwPacketHeader(data.getUint64(8, Endian.little),
        data.getUint64(16, Endian.little), rate);
  }
}

/// "Listen to laptop": the laptop plays the music with Live Transfer and
/// this device plays the processed audio, also in the background and with
/// the screen locked. It controls the laptop with the same requests and
/// control-lease rules as the iPad web page.
class LaptopListenController extends ChangeNotifier {
  LaptopListenController({
    required this.output,
    Future<Uri> Function(String entry)? resolveEntry,
    RemoteOwnerClient Function(Uri origin)? clientFor,
    this.retryDelay = const Duration(seconds: 1),
    this.leaseRenewal = const Duration(seconds: 10),
  })  : _resolveEntry = resolveEntry ?? resolveRemoteEntry,
        _clientFor =
            clientFor ?? ((origin) => RemoteOwnerClient(origin: origin));

  final LaptopListenOutput output;
  final Future<Uri> Function(String) _resolveEntry;
  final RemoteOwnerClient Function(Uri) _clientFor;
  final Duration retryDelay, leaseRenewal;

  RemoteOwnerClient? _client;
  WebSocket? _events, _audio;
  Timer? _renewTimer, _statusTimer;
  final _wakes = <Completer<void>>{};
  String? _lease;
  bool _wantControl = false, _renewing = false, _polling = false;
  bool _disposed = false;
  int _session = 0, _listenGeneration = 0, _writes = 0;
  String _nowPlayingKey = '';

  bool busy = false,
      connected = false,
      listening = false,
      audioConnected = false,
      pending = false,
      interrupted = false;
  Map<String, dynamic>? snapshot;
  String status = 'Sign in to your laptop to listen here.';

  /// The result of the last control tap, if any.
  String? notice;

  /// `live` (Live Transfer) or `file` (the laptop's own player).
  String audioSource = '';
  int received = 0, dropped = 0, played = 0, underruns = 0;
  int bufferMs = 0, queuedMs = 0;

  bool get signedIn => _client?.signedIn == true && snapshot != null;
  bool get hasControl => _lease != null;

  // ---------------------------------------------------------------- session

  Future<void> signIn(String entry, String username, String password) async {
    if (busy) return;
    busy = true;
    notice = null;
    _changed('Connecting to laptop…');
    await _endSession();
    final session = ++_session;
    try {
      final origin = await _resolveEntry(entry);
      if (session != _session) return;
      final client = _clientFor(origin);
      _client = client;
      final value = await client.signIn(username, password);
      if (session != _session) return;
      _applySnapshot(value['snapshot'] as Map<String, dynamic>);
      _changed('Signed in · connecting to the laptop…');
      _renewTimer =
          Timer.periodic(leaseRenewal, (_) => unawaited(_renewLease()));
      unawaited(_eventsLoop(session));
    } catch (error) {
      if (session != _session) return;
      _client?.close();
      _client = null;
      snapshot = null;
      _changed(_signInFailure(error));
    } finally {
      busy = false;
      _changed();
    }
  }

  static String _signInFailure(Object error) => switch (error) {
        RemoteEntryFailure(:final message) => message,
        RemoteApiException(statusCode: 401) =>
          'Owner account or password was rejected. Re-enter your laptop login.',
        RemoteApiException(statusCode: 429) =>
          'Too many sign-in attempts · wait a minute and try again.',
        RemoteApiException(:final statusCode) =>
          'Laptop connection failed (HTTP $statusCode) · check the laptop backend and try again.',
        TimeoutException() =>
          'Laptop connection timed out · check the laptop and network, then sign in again.',
        SocketException() =>
          'Cannot reach the laptop · check the internet connection and keep the laptop backend running.',
        HandshakeException() =>
          'Secure laptop connection failed · check the network and device date, then try again.',
        _ => 'Could not sign in. Check the laptop connection and owner login.',
      };

  Future<void> signOut() async {
    final client = _client;
    await stopListening();
    try {
      await client?.signOut();
    } catch (_) {}
    await _endSession();
    _changed('Signed out.');
  }

  /// The app is in the foreground again: reconnect now, not after backoff.
  void resumed() {
    for (final wake in _wakes.toList()) {
      if (!wake.isCompleted) wake.complete();
    }
    _wakes.clear();
  }

  Future<void> _endSession() async {
    await stopListening();
    ++_session;
    _renewTimer?.cancel();
    _renewTimer = null;
    final events = _events;
    _events = null;
    unawaited(events?.close(1000, 'signed_out'));
    _client?.close();
    _client = null;
    snapshot = null;
    connected = false;
    _lease = null;
    _wantControl = false;
    resumed();
  }

  bool _alive(int session) =>
      !_disposed && session == _session && _client != null;

  Future<void> _pause(int attempt) {
    final wake = Completer<void>();
    _wakes.add(wake);
    final delay = retryDelay * math.min(1 << math.min(attempt, 4), 10);
    return Future.any([Future<void>.delayed(delay), wake.future])
        .whenComplete(() => _wakes.remove(wake));
  }

  Future<void> _eventsLoop(int session) async {
    var attempt = 0;
    while (_alive(session)) {
      try {
        final socket = await _client!.openSocket('events');
        if (!_alive(session)) {
          unawaited(socket.close());
          return;
        }
        _events = socket;
        var sequence = 0;
        await for (final message in socket) {
          if (!_alive(session)) break;
          if (message is! String) continue;
          final data = jsonDecode(message);
          if (data is! Map ||
              data['type'] != 'snapshot' ||
              data['sequence'] is! int ||
              data['snapshot'] is! Map<String, dynamic> ||
              (data['sequence'] as int) <= sequence) {
            continue;
          }
          sequence = data['sequence'] as int;
          socket.add(jsonEncode({'ack': sequence}));
          attempt = 0;
          if (!connected) {
            connected = true;
            if (!listening) status = 'Connected to laptop.';
          }
          _applySnapshot(data['snapshot'] as Map<String, dynamic>);
        }
      } on RemoteApiException catch (error) {
        if (error.statusCode == 401) {
          if (_alive(session)) {
            await _endSession();
            _changed('The laptop signed this iPad out (it may have restarted) · '
                'sign in again.');
          }
          return;
        }
      } catch (_) {
        // Network drop or laptop restart: retry below.
      }
      if (!_alive(session)) return;
      _events = null;
      if (connected) {
        connected = false;
        _lease = null;
        _changed('Laptop connection lost · reconnecting…');
      }
      await _pause(attempt++);
    }
  }

  void _applySnapshot(Map<String, dynamic> value) {
    snapshot = value;
    if (value['controlOwned'] != true && _lease != null) {
      // Either the laptop took over or this snapshot predates the lease. An
      // automatic re-take tells them apart: the laptop refuses it after a
      // takeover.
      _lease = null;
      if (_wantControl) unawaited(_renewLease());
    }
    _updateNowPlaying();
    _changed();
  }

  // ---------------------------------------------------------------- control

  /// The user's "Take control" tap.
  Future<bool> takeControl() async {
    final client = _client;
    if (client == null || !connected) return false;
    try {
      _lease = await client.lease();
      _wantControl = true;
      notice = null;
      return true;
    } on RemoteApiException catch (error) {
      notice = failureText(error.code);
      return false;
    } catch (_) {
      notice = 'The laptop did not answer · try again.';
      return false;
    } finally {
      _changed();
    }
  }

  /// Renews the lease, or re-takes control this device had (after a network
  /// drop or a lapse while iPadOS paused the app).
  Future<void> _renewLease() async {
    final client = _client;
    if (client == null || !connected || !_wantControl || _renewing || pending) {
      return;
    }
    _renewing = true;
    try {
      _lease = await client.lease(auto: true);
    } on RemoteApiException catch (error) {
      _lease = null;
      // The laptop or another device has control: wait for a tap here.
      if (error.code == 'control_taken' || error.code == 'control_busy') {
        _wantControl = false;
        notice = failureText(error.code);
      }
    } catch (_) {
      // Network blip: the next renewal tries again.
    } finally {
      _renewing = false;
      _changed();
    }
  }

  /// Sends a laptop command (`media.next`, `point.set`, `live.start`…).
  Future<bool> command(String type,
          [Map<String, dynamic> payload = const {}]) =>
      _command(type, payload, false);

  Future<bool> _command(
      String type, Map<String, dynamic> payload, bool retried) async {
    final client = _client, state = snapshot, lease = _lease;
    if (client == null ||
        state == null ||
        lease == null ||
        (pending && !retried)) {
      return false;
    }
    pending = true;
    _changed();
    try {
      final result = await client.command(state, lease, type, payload);
      if (result['snapshot'] is Map<String, dynamic>) {
        _applySnapshot(result['snapshot'] as Map<String, dynamic>);
      }
      notice = result['status'] == 'native_applied'
          ? 'Applied on the laptop.'
          : 'The laptop’s own controls superseded this change.';
      return true;
    } on RemoteApiException catch (error) {
      // The laptop's state moved on (a song change) or the lease lapsed:
      // refresh, re-take control and try once more.
      if (!retried &&
          (error.code == 'stale_state' || error.code == 'control_lost')) {
        try {
          if (error.code == 'control_lost') {
            _lease = await client.lease(auto: true);
          }
          _applySnapshot(
              (await client.session())['snapshot'] as Map<String, dynamic>);
          return await _command(type, payload, true);
        } catch (_) {
          // Report the original failure below.
        }
      }
      // A refusal about the music or the mode keeps control; anything else
      // needs control again.
      if (!const {
        'media_command_failed',
        'no_music_app',
        'music_not_playing',
        'music_app_open_failed',
        'music_app_no_song',
        'live_start_failed',
        'array_active',
        'invalid_payload',
      }.contains(error.code)) {
        _lease = null;
      }
      notice = failureText(error.code);
      return false;
    } catch (_) {
      notice = 'The laptop did not answer · try again.';
      return false;
    } finally {
      pending = false;
      _changed();
    }
  }

  static String failureText(String code) => switch (code) {
        'no_music_app' => 'Open your music app on the laptop first.',
        'music_not_playing' =>
          'The laptop music app did not start playing. Check it on the laptop.',
        'music_app_open_failed' =>
          'The laptop could not open its music app. Open it on the laptop.',
        'music_app_no_song' =>
          'The music app opened on the laptop but has no song ready. Choose a song there once.',
        'live_start_failed' =>
          'Live Transfer did not start on the laptop. Check the laptop.',
        'media_command_failed' =>
          'The laptop music app did not accept that command.',
        'array_active' => 'Orbit is off in 2.0 mode.',
        'local_busy' => 'The laptop is busy right now. Try again in a moment.',
        'control_busy' =>
          'Another device has control (the web page?). Try again when it is done.',
        'control_taken' =>
          'Someone at the laptop took control. Tap Take control to change things here.',
        _ => 'Change not applied: ${code.replaceAll('_', ' ')}. Take control again.',
      };

  /// A lock-screen or Control Center button.
  Future<void> remote(String action) async {
    if (!listening || _client == null) return;
    // A tap right after another one waits for it instead of being dropped.
    for (var i = 0; pending && i < 30; ++i) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (pending || snapshot == null) return;
    if (_lease == null && !await takeControl()) return;
    final state = snapshot!;
    final live = state['liveRunning'] == true;
    final capabilities = _map(state['capabilities']);
    final playing = live
        ? _map(state['live'])['playing'] == true
        : _map(state['transport'])['playing'] == true;
    final wanted = action == 'toggle' ? (playing ? 'pause' : 'play') : action;
    final type = switch (wanted) {
      // Not live yet: play starts the music and Live Transfer on the laptop.
      'play' when !live && capabilities['remoteLive'] == true => 'live.start',
      'play' || 'pause' || 'next' || 'previous'
          when capabilities['liveMedia'] == true =>
        'media.$wanted',
      // No music-app control: the laptop's own player.
      'play' || 'pause' => wanted,
      _ => null,
    };
    if (type != null) await command(type);
  }

  // -------------------------------------------------------------- listening

  /// Opens the iPad audio, takes control (lock-screen buttons need it) and
  /// streams the laptop's audio. [startLive]: also start the music and Live
  /// Transfer on the laptop, like the web page's "Start on laptop".
  Future<void> startListening({bool startLive = false}) async {
    if (!signedIn || listening || busy) return;
    busy = true;
    notice = null;
    _changed('Opening iPad audio…');
    try {
      await output.prepare();
    } catch (_) {
      busy = false;
      _changed('Could not open iPad audio · close other audio apps and try again.');
      return;
    }
    listening = true;
    interrupted = false;
    received = dropped = played = underruns = bufferMs = queuedMs = 0;
    _writes = 0;
    _nowPlayingKey = '';
    final generation = ++_listenGeneration;
    output.setRemoteCommandHandler((action) => unawaited(remote(action)));
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500),
        (_) => unawaited(_pollOutput(generation)));
    busy = false;
    _updateNowPlaying();
    _changed('Connecting laptop audio…');
    unawaited(_audioLoop(generation, _session));
    // Right after sign-in the event stream may still be connecting.
    for (var i = 0; !connected && listening && i < 30; ++i) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_lease == null && listening) await takeControl();
    if (startLive && snapshot?['liveRunning'] != true) {
      _changed('Starting the music and Live Transfer on the laptop…');
      await command('live.start');
    }
  }

  Future<void> stopListening({String? message}) async {
    if (!listening) return;
    listening = false;
    audioConnected = false;
    interrupted = false;
    ++_listenGeneration;
    _statusTimer?.cancel();
    _statusTimer = null;
    final socket = _audio;
    _audio = null;
    unawaited(socket?.close(1000, 'stopped'));
    output.setRemoteCommandHandler(null);
    _writes = 0;
    try {
      await output.hideNowPlaying();
    } catch (_) {}
    try {
      await output.stop();
    } catch (_) {}
    _changed(message ?? 'Stopped listening · the laptop keeps playing.');
  }

  bool _listening(int generation, int session) =>
      listening && generation == _listenGeneration && _alive(session);

  Future<void> _audioLoop(int generation, int session) async {
    var attempt = 0;
    while (_listening(generation, session)) {
      String? reason;
      try {
        final socket = await _client!.openSocket('audio');
        if (!_listening(generation, session)) {
          unawaited(socket.close());
          return;
        }
        _audio = socket;
        int? epoch, rate;
        await for (final message in socket) {
          if (!_listening(generation, session)) break;
          if (message is String) {
            final data = jsonDecode(message);
            if (data is Map && data['type'] == 'audioReady') {
              audioConnected = true;
              attempt = 0;
              audioSource = data['source'] is String ? data['source'] : '';
              _changed(audioSource == 'live'
                  ? 'Listening · Live from the laptop'
                  : 'Listening · the laptop’s player');
            }
            continue;
          }
          if (message is! List<int>) continue;
          final packet =
              message is Uint8List ? message : Uint8List.fromList(message);
          final header = YnwPacketHeader.parse(packet);
          if (header == null) {
            ++dropped;
            continue;
          }
          socket.add(jsonEncode({'ack': header.sequence}));
          // A late packet from before a flush on the laptop.
          if (epoch != null && header.epoch < epoch) {
            ++dropped;
            continue;
          }
          if (header.epoch != epoch || header.sampleRate != rate) {
            epoch = header.epoch;
            rate = header.sampleRate;
            await output.newStream(header.sampleRate);
            if (!_listening(generation, session)) break;
          }
          ++received;
          _write(packet, generation);
        }
        reason = socket.closeReason;
      } on RemoteApiException catch (error) {
        if (error.statusCode == 401) return; // The events loop signs out.
        reason = error.code;
      } catch (_) {
        // Network drop: retry below.
      }
      _audio = null;
      if (!_listening(generation, session)) return;
      audioConnected = false;
      _changed(switch (reason) {
        'audio_busy' =>
          'Another device is listening (Safari?) · stop it there. Retrying…',
        'live_stopped' => 'Live stopped on the laptop · waiting for its audio…',
        'audio_source_changed' => 'Laptop audio changed · reconnecting…',
        'unsupported_stream' =>
          'The laptop has no audio to send yet · retrying…',
        _ => 'Laptop audio interrupted · reconnecting…',
      });
      await _pause(attempt++);
    }
  }

  void _write(Uint8List packet, int generation) {
    if (_writes >= 64 || interrupted) {
      ++dropped;
      return;
    }
    ++_writes;
    output.write(packet).then((accepted) {
      if (!accepted && generation == _listenGeneration) ++dropped;
    }, onError: (Object _) {
      if (generation == _listenGeneration) ++dropped;
    }).whenComplete(() {
      if (generation == _listenGeneration) --_writes;
    });
  }

  Future<void> _pollOutput(int generation) async {
    if (_polling || !listening || generation != _listenGeneration) return;
    _polling = true;
    try {
      final value = await output.status();
      if (!listening || generation != _listenGeneration) return;
      int number(String key) => value[key] is int ? value[key] as int : 0;
      played = number('played');
      underruns = number('underruns');
      bufferMs = number('bufferMs');
      queuedMs = number('queuedMs');
      final wasInterrupted = interrupted;
      interrupted = value['interrupted'] == true;
      if (value['ready'] == false && !interrupted) {
        await stopListening(
            message: 'iPad audio stopped (another app took over the sound) · '
                'tap Listen to continue.');
        return;
      }
      _changed(interrupted == wasInterrupted
          ? null
          : interrupted
              ? 'Paused by iPadOS (a call or another app) · resumes when it ends.'
              : 'Listening again.');
    } catch (_) {
      // Diagnostics only.
    } finally {
      _polling = false;
    }
  }

  void _updateNowPlaying() {
    final state = snapshot;
    if (!listening || state == null) return;
    final live = state['liveRunning'] == true;
    final liveInfo = _map(state['live']), track = _map(state['track']);
    final title = live
        ? _text(liveInfo['title'], 'Laptop music')
        : _text(track['title'], 'Yinwei laptop');
    final source = live
        ? _text(liveInfo['source'], '')
        : _text(track['artist'], '');
    final artist = source.isEmpty ? 'Yinwei laptop' : '$source · Yinwei laptop';
    final playing = live
        ? liveInfo['playing'] == true
        : _map(state['transport'])['playing'] == true;
    final key = jsonEncode([title, artist, playing]);
    if (key == _nowPlayingKey) return;
    _nowPlayingKey = key;
    unawaited(output
        .showNowPlaying(title: title, artist: artist, playing: playing)
        .catchError((Object _) {}));
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
  static String _text(Object? value, String fallback) =>
      value is String && value.trim().isNotEmpty ? value : fallback;

  void _changed([String? message]) {
    if (message != null) status = message;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_endSession());
    _disposed = true;
    super.dispose();
  }
}
